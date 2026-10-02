import Foundation

/// One transfer, start to finish, implementing the contract from
/// `offload-model.md`:
///
///     enumerate → copy → verify → manifest → report
///
/// Rules this type is built around:
/// - The source is never modified; `removeItem` is only ever called on
///   destination paths.
/// - The source is read exactly once; one streaming hash feeds every
///   destination comparison.
/// - Verification independently re-reads every destination copy (uncached).
/// - The manifest and Markdown report are written on every terminal path —
///   success, failure, and cancellation — and the event stream always ends
///   with `.finished`.
struct TransferWorker {
    let request: TransferRequest
    let configuration: TransferConfiguration
    let fileSystem: any FileSystemAccess
    let hub: ProgressHub
    let control: TransferControl

    private var items: [SourceItem] = []
    /// relativePath → source digest, computed once during the copy pass.
    private var digests: [String: String] = [:]
    /// Maximum-profile independent source pre-read digests.
    private var preReadDigests: [String: String] = [:]
    private var trustedSourceDigests: [String: String] = [:]
    private var outcomes: [String: [URL: ItemDestinationOutcome]] = [:]
    /// Copied-but-not-yet-verified pairs, per destination. Copied is not
    /// success; everything here must still pass the verify pass.
    private var pendingVerify: [URL: [(item: SourceItem, digest: String)]] = [:]
    private var pendingPaths: [URL: Set<String>] = [:]
    private var deadDestinations: Set<URL> = []
    private var sourceDead = false
    private var cancelled = false
    private var paused = false
    /// The request itself was invalid (e.g. a destination inside the source);
    /// zero items must not read as a vacuous success.
    private var vetoed = false
    private var transferIssues: [String] = []
    private let startedAt = Date()

    init(
        request: TransferRequest,
        configuration: TransferConfiguration,
        fileSystem: any FileSystemAccess,
        hub: ProgressHub,
        control: TransferControl = TransferControl()
    ) {
        self.request = request
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.hub = hub
        self.control = control
    }

    mutating func run() async {
        await hub.log(.info, "Transfer \(request.shortID): \(request.sourceRoot.path) → " +
            request.destinationRoots.map(\.path).joined(separator: ", "))

        if let veto = validateRequest() {
            vetoed = true
            await hub.log(.error, veto)
            // Do not touch the destinations at all on a vetoed request — one
            // veto reason is a destination nested inside the source.
            await finish(writeToDestinations: false)
            return
        }

        await hub.phase(.enumerating)
        do {
            items = try fileSystem.enumerate(root: request.sourceRoot)
        } catch {
            sourceDead = true
            transferIssues.append("The source could not be scanned: \(describe(error))")
            await hub.log(.error, "Could not enumerate source: \(describe(error))")
            await finish(writeToDestinations: true)
            return
        }
        let completePlan = items
        if let includedRelativePaths = request.includedRelativePaths {
            items = completePlan.filter { includedRelativePaths.contains($0.relativePath) }
            let discovered = Set(items.map(\.relativePath))
            let missing = includedRelativePaths.subtracting(discovered).sorted()
            if !missing.isEmpty {
                vetoed = true
                // The requested set is the contract: whether it came from a
                // fine-grained retry or an operator's own selection, a missing
                // item means the reviewed plan cannot be carried out.
                transferIssues.append(
                    "Requested source items are missing: " + missing.prefix(8).joined(separator: ", ")
                )
                await hub.log(.error, transferIssues.last ?? "Requested source items are missing")
                await finish(writeToDestinations: false)
                return
            }
        }
        let totalBytes = items.reduce(0) { $0 + $1.size }
        await hub.plan(totalBytes: totalBytes, itemsTotal: items.count)
        await hub.log(.info, "Plan: \(items.count) files, \(MarkdownReportWriter.byteString(totalBytes))")

        guard !items.isEmpty else {
            vetoed = true
            transferIssues.append("The source is empty; no media was copied.")
            await hub.log(.error, "Source is empty; refusing to report a verified transfer")
            await finish(writeToDestinations: false)
            return
        }
        if let expectedFingerprint = request.sourceFingerprint {
            // A fine-grained retry carries its parent's fingerprint, which
            // covers the parent's whole plan, not the failed pairs it
            // repairs: compare like with like. A resume and a selection-only
            // offload were reviewed as exactly their own items.
            let reviewedPlan: [SourceItem]
            if let parent = request.retryManifest {
                guard let parentPlan = Self.parentPlan(
                    of: parent, in: completePlan, fingerprint: expectedFingerprint
                ) else {
                    vetoed = true
                    transferIssues.append(Self.retryParentDoesNotDescribePlan)
                    await hub.log(.error, transferIssues.last ?? "Retry parent manifest unusable")
                    await finish(writeToDestinations: false)
                    return
                }
                reviewedPlan = parentPlan
            } else {
                reviewedPlan = items
            }
            if expectedFingerprint != SourcePlanFingerprint.make(reviewedPlan) {
                vetoed = true
                // A repair's manifest records its parent's plan identity over
                // only the files it repaired. Continuing one (a repair of a
                // repair, or a resume of a paused repair) lands here although
                // every file that record lists is still on the source exactly
                // as recorded: the record names another plan, and nothing on
                // the source changed. Say so instead of blaming the source.
                let continuedRecord = request.retryManifest ?? request.resumeManifest
                if let continuedRecord, Self.manifest(continuedRecord, stillDescribes: reviewedPlan) {
                    transferIssues.append(request.retryManifest == nil
                        ? Self.pausedRecordDoesNotDescribePlan
                        : Self.retryParentDoesNotDescribePlan)
                } else {
                    transferIssues.append("The source plan changed after review; run preflight again.")
                }
                await hub.log(.error, transferIssues.last ?? "Source plan changed")
                await finish(writeToDestinations: false)
                return
            }
        }
        // A resume carries on exactly the plan its paused record lists, which
        // names every planned file, attempted or not. A paused repair's
        // record lists only the failed pairs it was repairing, and a resume
        // has no authority to set failed bytes aside: resumed as the whole
        // card, every file the parent verified would fail as a name collision
        // with no digest, and so would every failed copy the repair had not
        // reached. Refuse before any destination is touched.
        if let pausedRecord = request.resumeManifest, !Self.manifest(pausedRecord, listsExactly: items) {
            vetoed = true
            transferIssues.append(Self.pausedRecordDoesNotDescribePlan)
            await hub.log(.error, transferIssues.last ?? "Paused attempt's manifest unusable")
            await finish(writeToDestinations: false)
            return
        }
        let sourceMHL = SourceMHLTrust.inspect(
            sourceRoot: request.sourceRoot,
            items: items,
            algorithm: request.algorithm,
            expectedFingerprint: request.sourceFingerprint,
            fileSystem: fileSystem
        )
        switch sourceMHL.state {
        case .absent: break
        case .validButUntrusted(let reason):
            await hub.log(.warning, "Source ASC MHL found but digests will not be reused: \(reason)")
        case .trusted:
            trustedSourceDigests = sourceMHL.digests
            await hub.log(.info, "Trusted source ASC MHL chain; reusing \(trustedSourceDigests.count) source digests")
        }
        await restoreVerifiedOutcomesFromPausedAttempt()
        guard validateRetryScope() else {
            vetoed = true
            await finish(writeToDestinations: false)
            return
        }
        let zeroByteItems = items.filter { $0.size == 0 }
        guard zeroByteItems.isEmpty else {
            vetoed = true
            transferIssues.append("Zero-byte source files detected: " +
                zeroByteItems.prefix(8).map(\.relativePath).joined(separator: ", "))
            for item in items {
                for destination in request.destinationRoots {
                    let outcome: ItemDestinationOutcome = item.size == 0
                        ? .failed(.zeroByteSource)
                        : .skipped(.sourceUnavailable)
                    await record(item.relativePath, destination, outcome)
                }
            }
            await hub.log(.error, "Zero-byte source media detected; refusing to touch destinations")
            await finish(writeToDestinations: false)
            return
        }

        await preflightDestinations(totalBytes: totalBytes)
        await verifyDuplicateCandidates()
        if request.verificationProfile == .maximum {
            await preReadSource()
        }
        if paused {
            await fillUnattemptedSkips()
        } else {
            await copyPass()
        }
        await verifyPass()
        await confirmSourcePlanUnchanged()
        await finish(writeToDestinations: true)
    }

    /// The current source items a fine-grained retry's parent attempt
    /// planned: the parent manifest's own paths, taken from the complete
    /// enumeration before the retry narrows it to the failed pairs. `nil`
    /// when the manifest cannot vouch for the reviewed plan: it names no
    /// files, names one twice, or records a different plan identity than the
    /// one the retry carries.
    private static func parentPlan(
        of parent: TransferManifest,
        in completePlan: [SourceItem],
        fingerprint: String
    ) -> [SourceItem]? {
        let paths = Set(parent.items.map(\.relativePath))
        guard !paths.isEmpty,
              paths.count == parent.items.count,
              parent.sourceFingerprint == nil || parent.sourceFingerprint == fingerprint
        else { return nil }
        return completePlan.filter { paths.contains($0.relativePath) }
    }

    private static let retryParentDoesNotDescribePlan =
        "The failed attempt's manifest does not describe the reviewed source plan; "
            + "the retry cannot be checked against it."

    private static let pausedRecordDoesNotDescribePlan =
        "The paused attempt's manifest does not describe the source plan being resumed; "
            + "the resume cannot continue it. Use Retry as New Offload instead."

    /// Whether `manifest` lists exactly the files of `plan`, each once.
    private static func manifest(_ manifest: TransferManifest, listsExactly plan: [SourceItem]) -> Bool {
        let paths = manifest.items.map(\.relativePath)
        return paths.count == plan.count && Set(paths) == Set(plan.map(\.relativePath))
    }

    /// Whether `manifest` lists exactly the files of `plan` and each still
    /// has the size and modification time it recorded: as far as that record
    /// reaches, the source is unchanged.
    private static func manifest(_ manifest: TransferManifest, stillDescribes plan: [SourceItem]) -> Bool {
        guard Self.manifest(manifest, listsExactly: plan) else { return false }
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        // Paths are unique here: the manifest lists exactly the plan's files.
        let recorded = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.relativePath, $0) })
        return plan.allSatisfy { item in
            guard let entry = recorded[item.relativePath], entry.size == item.size else { return false }
            return entry.modifiedAt == item.modificationTime.map { Date(timeIntervalSince1970: $0).formatted(iso) }
        }
    }

    // MARK: - Validation & preflight

    private func validateRequest() -> String? {
        guard !request.destinationRoots.isEmpty else { return "No destinations selected." }
        let source = fileSystem.canonicalURL(request.sourceRoot)
        let sourcePath = source.path
        let sourceVolume: FileSystemVolume
        do {
            sourceVolume = try fileSystem.volume(at: source)
        } catch {
            return "Could not identify source volume: \(describe(error))"
        }
        var seen = Set<String>()
        var seenVolumes: [FileSystemVolume] = []
        for destination in request.destinations {
            let base = fileSystem.canonicalURL(destination.baseRoot)
            let output = fileSystem.canonicalURL(destination.outputRoot)
            let destPath = output.path
            guard seen.insert(destPath).inserted else {
                return "Duplicate destination: \(destPath)"
            }
            if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
                return "Destination \(destPath) is inside the source. The source stays read-only; refusing to start."
            }
            if sourcePath.hasPrefix(destPath + "/") {
                return "Source is inside destination \(destPath); refusing to start."
            }
            do {
                let volume = try fileSystem.volume(at: base)
                if volume.isReadOnly {
                    return "Destination \(base.path) is read-only."
                }
                // Independence is a property of physical devices: two APFS
                // volumes or partitions on one disk, or two shares from one
                // server, are one failure domain, exactly like one volume.
                let sameVolume = volume.identifier == sourceVolume.identifier
                if sourceVolume.sharesPhysicalDevice(with: volume),
                   sourceVolume.isRemovable,
                   source.path == sourceVolume.mountPath {
                    // Formatting a card in camera rewrites the whole device,
                    // so no acknowledgement makes another partition a backup.
                    return sameVolume
                        ? "A removable source volume cannot also contain its destination."
                        : "A removable source's physical device cannot also hold destination \(base.path)."
                }
                if sourceVolume.sharesPhysicalDevice(with: volume), !request.allowSameVolume {
                    return sameVolume
                        ? "Source and destination \(base.path) are on the same volume. Explicit acknowledgement is required."
                        : "Source and destination \(base.path) are on the same physical device. "
                            + "Explicit acknowledgement is required."
                }
                if seenVolumes.contains(where: { $0.sharesPhysicalDevice(with: volume) }), !request.allowSameVolume {
                    return "Two destinations share the same physical volume. Explicit acknowledgement is required."
                }
                seenVolumes.append(volume)
            } catch {
                return "Could not identify destination volume for \(base.path): \(describe(error))"
            }
        }
        return nil
    }

    private mutating func preflightDestinations(totalBytes: Int64) async {
        for requested in request.destinations {
            let destination = requested.outputRoot
            guard fileSystem.fileExists(at: requested.baseRoot) else {
                await failWholeDestination(destination, reason: .destinationUnmounted,
                                           log: "Destination \(requested.baseRoot.path) is not mounted")
                continue
            }
            let duplicateCandidate = request.duplicateManifests[destination.path] != nil
            // A fresh offload's task folder must not already exist. A direct
            // output ("Directly in destination") is the operator's own base,
            // which always exists and can never be new; it is protected per
            // file instead — exclusive staging, exclusive publish, and a name
            // collision that fails that file without replacing it. Compared
            // literally, never through symlink resolution, so a task folder
            // that merely resolves to its base still counts as existing.
            let writesDirectlyIntoBase = destination.path == requested.baseRoot.path
            if fileSystem.fileExists(at: destination),
               !writesDirectlyIntoBase,
               (request.requireNewOutputRoots
                    || (!request.duplicateManifests.isEmpty
                        && !duplicateCandidate
                        && request.resumeManifest == nil
                        && request.retryManifest == nil)) {
                await failWholeDestination(destination, reason: .nameCollision,
                                           log: "Output folder already exists: \(destination.path)")
                continue
            }
            do {
                try fileSystem.createDirectory(at: destination)
            } catch {
                await failWholeDestination(destination, reason: writeFailureReason(error),
                                           log: "Could not create output folder \(destination.path)")
                continue
            }
            if let volume = try? fileSystem.volume(at: requested.baseRoot),
               let issue = destinationCompatibilityIssue(destination, volume: volume) {
                await failWholeDestination(
                    destination,
                    reason: .writeFailed(detail: issue),
                    log: issue
                )
                continue
            }
            let reserve = max(Int64(512 * 1024 * 1024), totalBytes / 20)
            if !duplicateCandidate,
               let free = try? fileSystem.freeSpace(at: requested.baseRoot), free < totalBytes + reserve {
                await failWholeDestination(destination, reason: .destinationFull,
                                           log: "Destination \(requested.baseRoot.path) has " +
                                           "\(MarkdownReportWriter.byteString(free)) free, needs " +
                                           MarkdownReportWriter.byteString(totalBytes + reserve))
            }
        }
    }

    private func destinationCompatibilityIssue(
        _ destination: URL,
        volume: FileSystemVolume
    ) -> String? {
        if volume.supportsCaseSensitiveNames == false {
            let groups = Dictionary(grouping: items) {
                $0.relativePath.precomposedStringWithCanonicalMapping
                    .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }
            if let collision = groups.values.first(where: { $0.count > 1 }) {
                return "Destination \(volume.name) is case-insensitive; source paths collide: "
                    + collision.prefix(3).map(\.relativePath).joined(separator: ", ")
            }
        }
        if let limit = volume.maximumNameBytes,
           let item = items.first(where: {
               $0.relativePath.split(separator: "/").contains { $0.utf8.count > limit }
           }) {
            return "Filename exceeds destination's \(limit)-byte limit: \(item.relativePath)"
        }
        if let limit = volume.maximumPathBytes,
           let item = items.first(where: {
               destination.appendingPathComponent($0.relativePath).path.utf8.count + 1 > limit
           }) {
            return "Path exceeds destination's \(limit)-byte limit: \(item.relativePath)"
        }
        return nil
    }

    /// Preflight-level failure: every item fails at this destination, loudly.
    private mutating func failWholeDestination(_ destination: URL, reason: ItemFailureReason, log message: String) async {
        deadDestinations.insert(destination)
        await hub.log(.error, message)
        for item in items {
            await record(item.relativePath, destination, .failed(reason))
        }
    }

    // MARK: - Copy pass

    private mutating func preReadSource() async {
        await hub.phase(.preReadingSource)
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        for item in items {
            guard !Task.isCancelled else {
                cancelled = true
                return
            }
            do {
                let reader = try fileSystem.openForReading(
                    request.sourceRoot.appendingPathComponent(item.relativePath),
                    uncached: true
                )
                defer { reader.close() }
                var hasher = request.algorithm.makeHasher()
                while true {
                    let count = try reader.read(into: &buffer)
                    if count == 0 { break }
                    buffer.withUnsafeBytes { raw in
                        hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                    }
                }
                preReadDigests[item.relativePath] = hasher.hexDigest()
                if await control.shouldPause() {
                    paused = true
                    return
                }
            } catch {
                // Same split as the copy pass: a vanished source root ends the
                // offload, but one unreadable file (a bad sector, a permissions
                // error) fails only that item at every live destination, and
                // every readable file is still pre-read, copied and verified.
                await sourceReadFailed(item, error: error)
                if sourceDead {
                    transferIssues.append(
                        "Maximum source pre-read failed at \(item.relativePath): \(describe(error))"
                    )
                    return
                }
                if await control.shouldPause() {
                    paused = true
                    return
                }
            }
        }
    }

    private mutating func copyPass() async {
        await hub.phase(.copying)
        for item in items {
            if Task.isCancelled { cancelled = true }
            if cancelled || sourceDead { break }
            if deadDestinations.count == request.destinationRoots.count { break }
            await hub.beginItem(item.relativePath)
            await copy(item)
            await hub.finishItem()
            if await control.shouldPause() {
                paused = true
                await hub.log(.warning, "Pause requested; stopped at a complete-file boundary")
                break
            }
        }
        if Task.isCancelled { cancelled = true }
        await fillUnattemptedSkips()
    }

    private final class WriterStreamBox: @unchecked Sendable {
        let stream: any FileWriteStream
        init(_ stream: any FileWriteStream) { self.stream = stream }
    }

    private struct DestinationWriter {
        let destination: URL
        let target: URL
        let staging: URL
        let channel: BoundedAsyncChannel<[UInt8]>
        let task: Task<FileSystemError?, Never>
    }

    private mutating func copy(_ item: SourceItem) async {
        let liveDestinations = request.destinationRoots.filter {
            !deadDestinations.contains($0)
                && outcomes[item.relativePath]?[$0]?.isVerified != true
                // Kept from a paused Fast attempt: already published here and
                // owed a read-back, never a second copy.
                && outcomes[item.relativePath]?[$0]?.isTransferredPendingVerification != true
        }
        guard !liveDestinations.isEmpty else { return }
        // Maximum never copies bytes its independent pre-read did not hash.
        // `preReadSource` has already failed such an item; letting it through
        // would compare a nil pre-read digest below and misreport a source
        // change that ends the whole offload.
        if request.verificationProfile == .maximum, preReadDigests[item.relativePath] == nil {
            for destination in liveDestinations where outcomes[item.relativePath]?[destination] == nil {
                await record(item.relativePath, destination, .failed(.sourceUnreadable(
                    detail: "Maximum independent pre-read did not complete for this file"
                )))
            }
            return
        }

        var writers: [DestinationWriter] = []
        for destination in liveDestinations {
            let target = destination.appendingPathComponent(item.relativePath)
            let staging = target.deletingLastPathComponent().appendingPathComponent(
                ".doppelganger-partial-\(request.shortID)-\(target.lastPathComponent)"
            )
            do {
                try fileSystem.createDirectory(at: target.deletingLastPathComponent())
                if fileSystem.fileExists(at: target) {
                    switch try await resolveExistingRetryTarget(target, item: item, destination: destination) {
                    case .quarantined:
                        break
                    case .provenDuplicate(let sourceDigest):
                        // Proven identical to the source: kept in place, never
                        // rewritten, and no writer is needed here.
                        digests[item.relativePath] = sourceDigest
                        await record(item.relativePath, destination, .verifiedDuplicate)
                        await hub.log(.info, "Existing copy proven identical and kept: \(item.relativePath) at \(destination.path)")
                        continue
                    case .refused:
                        throw FileSystemError.alreadyExists
                    }
                }
                let stream = WriterStreamBox(try fileSystem.openForWritingExclusive(staging))
                let channel = BoundedAsyncChannel<[UInt8]>(capacity: 2)
                let progressHub = hub
                let writerTask = Task.detached(priority: .userInitiated) { () -> FileSystemError? in
                    do {
                        while let chunk = await channel.next() {
                            try stream.stream.write(chunk, count: chunk.count)
                            await progressHub.addCopiedBytes(chunk.count, at: destination)
                        }
                        try stream.stream.close()
                        return nil
                    } catch {
                        try? stream.stream.close()
                        await channel.close()
                        return Self.pipelineError(error)
                    }
                }
                writers.append(DestinationWriter(
                    destination: destination,
                    target: target,
                    staging: staging,
                    channel: channel,
                    task: writerTask
                ))
            } catch FileSystemError.alreadyExists {
                // Collision fails this item here but does not kill the
                // destination — and never overwrites the existing file.
                await record(item.relativePath, destination, .failed(.nameCollision))
                await hub.log(.error, "\(item.relativePath): already exists at \(destination.path)")
            } catch {
                await destinationFailed(destination, item: item, error: error)
            }
        }
        guard !writers.isEmpty else { return }

        let reader: any FileReadStream
        do {
            reader = try fileSystem.openForReading(request.sourceRoot.appendingPathComponent(item.relativePath), uncached: false)
        } catch {
            for writer in writers {
                await writer.channel.close()
                _ = await writer.task.value
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceReadFailed(item, error: error)
            return
        }
        defer { reader.close() }

        var hasher = request.algorithm.makeHasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        var activeChannels = Dictionary(uniqueKeysWithValues: writers.map { ($0.destination, $0.channel) })
        var bytesRead: Int64 = 0
        var readError: Error?
        var cancelledMidCopy = false

        while true {
            if Task.isCancelled {
                cancelled = true
                cancelledMidCopy = true
                break
            }

            let count: Int
            do {
                count = try reader.read(into: &buffer)
            } catch {
                readError = error
                break
            }
            if count == 0 { break }
            bytesRead += Int64(count)

            if trustedSourceDigests[item.relativePath] == nil || request.verificationProfile == .maximum {
                buffer.withUnsafeBytes { raw in
                    hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                }
            }

            let chunk = Array(buffer[0..<count])
            let channels = activeChannels
            let accepted = await withTaskGroup(of: (URL, Bool).self) { group in
                for (destination, channel) in channels {
                    group.addTask { (destination, await channel.send(chunk)) }
                }
                var results: [(URL, Bool)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (destination, didAccept) in accepted where !didAccept {
                activeChannels.removeValue(forKey: destination)
            }
            if accepted.contains(where: { $0.1 }) {
                await hub.addCopiedBytes(count)
            }
            if activeChannels.isEmpty { break }
        }

        if cancelledMidCopy || readError != nil {
            for writer in writers { await writer.channel.close() }
        } else {
            for writer in writers { await writer.channel.finish() }
        }

        var successfulWriters: [DestinationWriter] = []
        for writer in writers {
            if let error = await writer.task.value {
                try? fileSystem.removeItem(at: writer.staging)
                await destinationFailed(writer.destination, item: item, error: error)
            } else {
                successfulWriters.append(writer)
            }
        }

        if cancelledMidCopy {
            for writer in successfulWriters {
                try? fileSystem.removeItem(at: writer.staging)
                await record(item.relativePath, writer.destination, .failed(.cancelled))
            }
            await hub.log(.warning, "\(item.relativePath): cancelled mid-copy; partial copies removed")
            return
        }
        if let readError {
            for writer in successfulWriters { try? fileSystem.removeItem(at: writer.staging) }
            await sourceReadFailed(item, error: readError)
            return
        }
        guard !successfulWriters.isEmpty else { return }

        guard bytesRead == item.size, sourceStillMatches(item) else {
            for writer in successfulWriters {
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceChanged(item)
            return
        }

        let digest = request.verificationProfile == .maximum
            ? hasher.hexDigest()
            : trustedSourceDigests[item.relativePath] ?? hasher.hexDigest()
        if let previousDigest = digests[item.relativePath], previousDigest != digest {
            for writer in successfulWriters {
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceChanged(item)
            return
        }
        if request.verificationProfile == .maximum,
           preReadDigests[item.relativePath] != digest {
            for writer in successfulWriters {
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceChanged(item)
            return
        }
        digests[item.relativePath] = digest

        for writer in successfulWriters {
            do {
                try fileSystem.moveItemExclusive(from: writer.staging, to: writer.target)
                if let modificationTime = item.modificationTime {
                    try fileSystem.setModificationTime(modificationTime, at: writer.target)
                }
                pendingVerify[writer.destination, default: []].append((item, digest))
                pendingPaths[writer.destination, default: []].insert(item.relativePath)
            } catch FileSystemError.alreadyExists {
                try? fileSystem.removeItem(at: writer.staging)
                await record(item.relativePath, writer.destination, .failed(.nameCollision))
                await hub.log(.error, "\(item.relativePath): appeared at \(writer.destination.path) during copy")
            } catch {
                try? fileSystem.removeItem(at: writer.staging)
                await destinationFailed(writer.destination, item: item, error: error)
            }
        }
    }

    private static func pipelineError(_ error: Error) -> FileSystemError {
        if let error = error as? FileSystemError { return error }
        return .other(code: -1, detail: error.localizedDescription)
    }

    private func sourceStillMatches(_ item: SourceItem) -> Bool {
        guard let current = try? fileSystem.sourceItem(
            at: request.sourceRoot.appendingPathComponent(item.relativePath),
            relativeTo: request.sourceRoot
        ) else { return false }
        guard current.size == item.size else { return false }
        switch (item.modificationTime, current.modificationTime) {
        case let (planned?, now?): return abs(planned - now) < 0.001
        default: return true
        }
    }

    private mutating func sourceChanged(_ item: SourceItem) async {
        sourceDead = true
        transferIssues.append("Source changed while copying: \(item.relativePath)")
        for destination in request.destinationRoots
        where outcomes[item.relativePath]?[destination] == nil && !deadDestinations.contains(destination) {
            await record(item.relativePath, destination, .failed(.sourceChanged))
        }
        await hub.log(.error, "\(item.relativePath): source changed during transfer")
    }

    private mutating func destinationFailed(_ destination: URL, item: SourceItem, error: Error) async {
        let reason = writeFailureReason(error)
        deadDestinations.insert(destination)
        await record(item.relativePath, destination, .failed(reason))
        await hub.log(.error, "Destination \(destination.path) failed at \(item.relativePath): " +
            reason.slug + (reason.detail.map { " — \($0)" } ?? ""))
    }

    private mutating func sourceReadFailed(_ item: SourceItem, error: Error) async {
        // A vanished source root is a different animal from one unreadable
        // file: the former ends the copy pass, the latter fails one item.
        let rootGone = !fileSystem.fileExists(at: request.sourceRoot)
        let reason: ItemFailureReason = rootGone
            ? .sourceUnmounted
            : .sourceUnreadable(detail: describe(error))
        if rootGone { sourceDead = true }
        for destination in request.destinationRoots
        where outcomes[item.relativePath]?[destination] == nil && !deadDestinations.contains(destination) {
            await record(item.relativePath, destination, .failed(reason))
        }
        await hub.log(.error, "\(item.relativePath): \(reason.slug)" +
            (reason.detail.map { " — \($0)" } ?? ""))
    }

    /// Every item × destination pair that was never attempted gets an explicit
    /// skip with a reason. No pair is left without an outcome.
    private mutating func fillUnattemptedSkips() async {
        for item in items {
            for destination in request.destinationRoots {
                guard outcomes[item.relativePath]?[destination] == nil else { continue }
                guard pendingPaths[destination]?.contains(item.relativePath) != true else { continue }
                let reason: ItemSkipReason = if deadDestinations.contains(destination) {
                    .destinationUnavailable
                } else if sourceDead {
                    .sourceUnavailable
                } else if paused {
                    .paused
                } else {
                    .cancelled
                }
                await record(item.relativePath, destination, .skipped(reason))
            }
        }
    }

    // MARK: - Verify pass

    private mutating func verifyPass() async {
        await hub.phase(.verifying)
        if Task.isCancelled { cancelled = true }
        if cancelled {
            // Copied-but-unverified is not success. Everything pending becomes
            // an explicit skip.
            for (destination, pairs) in pendingVerify {
                for pair in pairs {
                    await record(pair.item.relativePath, destination, .skipped(.cancelled))
                }
            }
            pendingVerify = [:]
            return
        }

        let fileSystem = fileSystem
        let chunkSize = configuration.chunkSize
        let algorithm = request.algorithm
        let hub = hub
        let work = pendingVerify

        if request.verificationProfile == .fast {
            for (destination, pairs) in work {
                for pair in pairs {
                    let target = destination.appendingPathComponent(pair.item.relativePath)
                    let outcome: ItemDestinationOutcome
                    if let observed = try? fileSystem.sourceItem(at: target, relativeTo: destination),
                       observed.size == pair.item.size {
                        outcome = .transferredPendingVerification
                    } else {
                        outcome = .failed(.writeFailed(detail: "Destination metadata did not match the copied source item"))
                    }
                    await record(pair.item.relativePath, destination, outcome)
                }
            }
            pendingVerify = [:]
            return
        }

        let results = await withTaskGroup(of: (URL, [(String, ItemDestinationOutcome)]).self) { group in
            for (destination, pairs) in work {
                let sendablePairs = pairs.map { (path: $0.item.relativePath, digest: $0.digest) }
                group.addTask {
                    let outcomes = await Self.verifyDestination(
                        destination: destination,
                        pairs: sendablePairs,
                        fileSystem: fileSystem,
                        chunkSize: chunkSize,
                        algorithm: algorithm,
                        hub: hub
                    )
                    return (destination, outcomes)
                }
            }
            var collected: [(URL, [(String, ItemDestinationOutcome)])] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Children already emitted their itemOutcome events; just merge state.
        for (destination, list) in results {
            for (path, outcome) in list {
                outcomes[path, default: [:]][destination] = outcome
            }
        }
        if Task.isCancelled { cancelled = true }
    }

    /// Restores pairs a prior paused attempt in this task already settled,
    /// when the source-plan metadata and the destination file still match.
    /// Everything else goes through `copy()`, which never overwrites an
    /// existing file: it fails as a name collision instead.
    ///
    /// - `verified`: restored as verified when the destination size matches.
    /// - `transferred-pending-verification`: restored as pending, never as
    ///   verified, and only when this resume and the paused attempt are both
    ///   Fast and the destination still has the source's size and a
    ///   modification time this task gave it (`publishedTimestampMatches`).
    ///   That is the same metadata-only evidence a Fast copy records. The
    ///   paused attempt's source digest is carried forward so a later
    ///   standalone verification can read the copy back.
    private mutating func restoreVerifiedOutcomesFromPausedAttempt() async {
        guard let manifest = request.resumeManifest,
              manifest.algorithm == request.algorithm.rawValue
                || (manifest.algorithm == "xxh64" && request.algorithm == .xxh64)
        else { return }
        // Only Fast writes pending pairs, and only a Fast resume may carry them
        // forward unread: Standard and Maximum owe a read-back of every copy.
        let carriesPendingPairs = request.verificationProfile == .fast
            && manifest.verificationProfile == VerificationProfile.fast.rawValue
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let pausedRun = Self.runInterval(of: manifest, format: iso)
        let records = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.relativePath, $0) })
        var keptPending = 0
        for item in items {
            guard let record = records[item.relativePath],
                  record.size == item.size,
                  let digest = record.digest
            else { continue }
            if let priorModified = record.modifiedAt,
               let currentModified = item.modificationTime.map({
                   Date(timeIntervalSince1970: $0).formatted(iso)
               }), priorModified != currentModified {
                continue
            }
            digests[item.relativePath] = digest
            for destination in request.destinationRoots {
                let prior = record.results.filter { $0.destination == destination.path }
                let target = destination.appendingPathComponent(item.relativePath)
                guard let observed = try? fileSystem.sourceItem(at: target, relativeTo: destination),
                      observed.size == item.size else { continue }
                if prior.contains(where: { $0.status == "verified" }) {
                    outcomes[item.relativePath, default: [:]][destination] = .verified
                } else if carriesPendingPairs,
                          prior.count == 1,
                          prior[0].status == "transferred-pending-verification",
                          Self.publishedTimestampMatches(
                              planned: item.modificationTime,
                              observed: observed.modificationTime,
                              pausedRun: pausedRun
                          ) {
                    outcomes[item.relativePath, default: [:]][destination] = .transferredPendingVerification
                    keptPending += 1
                }
            }
        }
        if keptPending > 0 {
            await hub.log(.info, "Resume: kept \(keptPending) copy result(s) the paused Fast attempt already " +
                "transferred; they were not rewritten and still need independent verification")
        }
    }

    /// A Fast copy is published with the source's modification time, which a
    /// destination filesystem stores at its own granularity (HFS+ one second,
    /// FAT two). A destination that does not keep timestamps (some exFAT and
    /// SMB mounts) leaves the copy with its publish time instead, inside the
    /// paused attempt's own run. A file with any other time is not the copy
    /// this task published. A source with no timestamp gave its copy none to
    /// compare.
    private static func publishedTimestampMatches(
        planned: TimeInterval?,
        observed: TimeInterval?,
        pausedRun: ClosedRange<TimeInterval>?
    ) -> Bool {
        guard let planned else { return true }
        guard let observed else { return false }
        if abs(planned - observed) <= 2 { return true }
        guard let pausedRun else { return false }
        return observed >= pausedRun.lowerBound - 2 && observed <= pausedRun.upperBound + 2
    }

    /// When the attempt `manifest` records ran, or `nil` if it cannot say.
    private static func runInterval(
        of manifest: TransferManifest,
        format: Date.ISO8601FormatStyle
    ) -> ClosedRange<TimeInterval>? {
        guard let started = try? Date(manifest.startedAt, strategy: format),
              let finished = try? Date(manifest.finishedAt, strategy: format),
              started <= finished
        else { return nil }
        return started.timeIntervalSince1970...finished.timeIntervalSince1970
    }

    /// Existing output is only a metadata candidate. Every proposed skip
    /// independently hashes the current source and destination, compares both
    /// to the immutable prior digest, and records a distinct verified-skip
    /// outcome. A mismatch falls through to collision handling; it is never
    /// overwritten.
    private mutating func verifyDuplicateCandidates() async {
        guard !request.duplicateManifests.isEmpty else { return }
        let progressHub = hub
        await hub.log(.info, "Checking prior verified outputs for digest-proven duplicate skips")
        for item in items {
            let candidates: [(URL, TransferManifest.ItemRecord)] = request.destinationRoots.compactMap { destination in
                guard !deadDestinations.contains(destination),
                      let manifest = request.duplicateManifests[destination.path],
                      manifest.sourceFingerprint == SourcePlanFingerprint.make(items),
                      let record = manifest.items.first(where: { $0.relativePath == item.relativePath }),
                      record.size == item.size,
                      record.results.contains(where: {
                          $0.destination == destination.path && $0.status == "verified"
                      }),
                      record.digest != nil
                else { return nil }
                return (destination, record)
            }
            guard !candidates.isEmpty else { continue }
            let sourceDigest: String
            do {
                sourceDigest = try await hashFile(
                    request.sourceRoot.appendingPathComponent(item.relativePath),
                    uncached: true
                )
            } catch {
                await hub.log(.warning, "Could not prove duplicate source \(item.relativePath): \(describe(error))")
                continue
            }
            guard sourceStillMatches(item) else {
                await sourceChanged(item)
                return
            }
            digests[item.relativePath] = sourceDigest
            for (destination, priorRecord) in candidates {
                guard priorRecord.digest == sourceDigest else {
                    await hub.log(.warning, "Prior digest no longer matches source: \(item.relativePath)")
                    continue
                }
                let target = destination.appendingPathComponent(item.relativePath)
                guard let observed = try? fileSystem.sourceItem(at: target, relativeTo: destination),
                      observed.size == item.size
                else { continue }
                do {
                    let destinationDigest = try await hashFile(target, uncached: true) { count in
                        await progressHub.addVerifiedBytes(count, at: destination)
                    }
                    guard destinationDigest == sourceDigest else {
                        await hub.log(.warning, "Existing destination digest mismatch: \(item.relativePath) at \(destination.path)")
                        continue
                    }
                    await record(item.relativePath, destination, .verifiedDuplicate)
                    await hub.log(.info, "Verified duplicate skipped: \(item.relativePath) at \(destination.path)")
                } catch {
                    await hub.log(.warning, "Could not prove destination duplicate \(item.relativePath): \(describe(error))")
                }
            }
        }
    }

    private func hashFile(
        _ url: URL,
        uncached: Bool,
        progress: ((Int) async -> Void)? = nil
    ) async throws -> String {
        let stream = try fileSystem.openForReading(url, uncached: uncached)
        defer { stream.close() }
        var hasher = request.algorithm.makeHasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        while true {
            let count = try stream.read(into: &buffer)
            if count == 0 { break }
            buffer.withUnsafeBytes { raw in
                hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
            await progress?(count)
        }
        return hasher.hexDigest()
    }

    /// A retry is deliberately narrower than a resume: it may address only
    /// pairs that the parent attempt did not verify, and the source metadata
    /// must still match that immutable parent record.
    private mutating func validateRetryScope() -> Bool {
        guard let manifest = request.retryManifest else { return true }
        guard request.resumeManifest == nil,
              request.destinationRoots.count == 1,
              let included = request.includedRelativePaths,
              !included.isEmpty,
              manifest.algorithm == request.algorithm.rawValue
                || (manifest.algorithm == "xxh64" && request.algorithm == .xxh64)
        else {
            transferIssues.append("The fine-grained retry request is invalid or uses a different checksum.")
            return false
        }
        let destination = request.destinationRoots[0]
        let records = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.relativePath, $0) })
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for item in items {
            guard included.contains(item.relativePath),
                  let record = records[item.relativePath],
                  record.size == item.size,
                  record.results.contains(where: {
                      $0.destination == destination.path && $0.status != "verified"
                  })
            else {
                transferIssues.append("The parent attempt does not authorize retrying \(item.relativePath).")
                return false
            }
            if let priorModified = record.modifiedAt,
               let currentModified = item.modificationTime.map({
                   Date(timeIntervalSince1970: $0).formatted(iso)
               }), priorModified != currentModified {
                transferIssues.append("The source changed since the failed attempt: \(item.relativePath).")
                return false
            }
        }
        return true
    }

    /// What a fine-grained retry may do with a file already at its target.
    private enum ExistingRetryTarget {
        /// The parent's own failed bytes were set aside; publish a fresh copy.
        case quarantined
        /// The file there is proven to hold the source's bytes; keep it.
        case provenDuplicate(sourceDigest: String)
        /// Unproven: the pair fails as a collision and the file is untouched.
        case refused
    }

    /// Decides what a retry does with an existing destination file. Nothing
    /// is ever overwritten, and a file is moved only on proof:
    ///
    /// - The parent recorded a checksum mismatch for this path at this
    ///   destination, with the digest it read back, and the file there still
    ///   hashes to that digest: those are the parent's own failed bytes, so
    ///   they are set aside under `.doppelganger-failed/<parent>/` (one slot
    ///   per parent and path) and a fresh copy is published.
    /// - The file there hashes to the parent's recorded source digest and the
    ///   current source re-hashes to it too: the copy is already correct (the
    ///   parent published it but never finished verifying it, or an earlier
    ///   repair fixed it), so it is kept in place as a verified duplicate.
    ///
    /// Anything else, including a parent that never wrote the path (a name
    /// collision, a whole-destination preflight failure, a skipped pair) or
    /// bytes that match neither digest (another task's verified copy), is
    /// refused: the pair fails as a collision and the file stays put.
    private func resolveExistingRetryTarget(
        _ target: URL,
        item: SourceItem,
        destination: URL
    ) async throws -> ExistingRetryTarget {
        guard let manifest = request.retryManifest,
              let record = manifest.items.first(where: { $0.relativePath == item.relativePath }),
              let parentResult = record.results.first(where: { $0.destination == destination.path })
        else { return .refused }
        // Identity before anything else, uncached like verification.
        // Unreadable bytes are unproven.
        guard let targetDigest = try? await hashFile(target, uncached: true) else { return .refused }

        if parentResult.status == "failed",
           parentResult.reason == ItemFailureReason.checksumMismatch(expected: "", actual: "").slug,
           parentResult.actualDigest == targetDigest {
            let parentID = (manifest.attemptID ?? manifest.transferID).prefix(8).lowercased()
            let quarantine = destination
                .appendingPathComponent(".doppelganger-failed", isDirectory: true)
                .appendingPathComponent(parentID, isDirectory: true)
                .appendingPathComponent(item.relativePath)
            guard !fileSystem.fileExists(at: quarantine) else { return .refused }
            try fileSystem.createDirectory(at: quarantine.deletingLastPathComponent())
            try fileSystem.moveItemExclusive(from: target, to: quarantine)
            return .quarantined
        }

        guard let priorDigest = record.digest, targetDigest == priorDigest, sourceStillMatches(item),
              let sourceDigest = try? await hashFile(
                  request.sourceRoot.appendingPathComponent(item.relativePath),
                  uncached: true
              ),
              sourceDigest == priorDigest, sourceStillMatches(item)
        else { return .refused }
        return .provenDuplicate(sourceDigest: sourceDigest)
    }

    private mutating func confirmSourcePlanUnchanged() async {
        guard !sourceDead, !cancelled else { return }
        guard var current = try? fileSystem.enumerate(root: request.sourceRoot) else {
            vetoed = true
            transferIssues.append("The source could not be scanned after the transfer.")
            await hub.log(.error, "Source could not be re-scanned; transfer cannot be trusted")
            return
        }
        if let included = request.includedRelativePaths {
            current = current.filter { included.contains($0.relativePath) }
        }
        guard current == items else {
            vetoed = true
            transferIssues.append("The source file list changed before the transfer finished.")
            await hub.log(.error, "Source file list changed after planning; transfer cannot be trusted")
            return
        }
    }

    /// One child task per destination: destinations are independent devices,
    /// so this is the parallelism that pays. Each copied file is re-read
    /// through a fresh, uncached stream and hashed from scratch.
    private static func verifyDestination(
        destination: URL,
        pairs: [(path: String, digest: String)],
        fileSystem: any FileSystemAccess,
        chunkSize: Int,
        algorithm: ChecksumAlgorithm,
        hub: ProgressHub
    ) async -> [(String, ItemDestinationOutcome)] {
        var results: [(String, ItemDestinationOutcome)] = []
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        for pair in pairs {
            var outcome: ItemDestinationOutcome
            if Task.isCancelled {
                outcome = .skipped(.cancelled)
            } else {
                do {
                    let reader = try fileSystem.openForReading(
                        destination.appendingPathComponent(pair.path), uncached: true)
                    defer { reader.close() }
                    var hasher = algorithm.makeHasher()
                    var interrupted = false
                    while true {
                        if Task.isCancelled {
                            interrupted = true
                            break
                        }
                        let count = try reader.read(into: &buffer)
                        if count == 0 { break }
                        buffer.withUnsafeBytes { raw in
                            hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                        }
                        await hub.addVerifiedBytes(count, at: destination)
                    }
                    if interrupted {
                        outcome = .skipped(.cancelled)
                    } else {
                        let actual = hasher.hexDigest()
                        outcome = actual == pair.digest
                            ? .verified
                            : .failed(.checksumMismatch(expected: pair.digest, actual: actual))
                    }
                } catch {
                    outcome = .failed(verifyFailureReason(error))
                }
            }

            if case .failed(let reason) = outcome {
                await hub.log(.error, "Verification FAILED: \(pair.path) at \(destination.path) — " +
                    reason.slug + (reason.detail.map { " — \($0)" } ?? ""))
            }
            results.append((pair.path, outcome))
            await hub.outcome(pair.path, destination: destination, outcome)
        }
        return results
    }

    // MARK: - Manifest & report

    /// The single terminal funnel. Builds the report from current state,
    /// writes the JSON manifest and Markdown report to every reachable
    /// destination plus the spool directory, then emits `.finished`.
    private mutating func finish(writeToDestinations: Bool) async {
        await hub.phase(.writingManifest)
        if Task.isCancelled { cancelled = true }

        let allVerified = items.allSatisfy { item in
            request.destinationRoots.allSatisfy { destination in
                outcomes[item.relativePath]?[destination]?.isVerified == true
            }
        }
        let allTransferredPendingVerification = items.allSatisfy { item in
            request.destinationRoots.allSatisfy { destination in
                outcomes[item.relativePath]?[destination]?.isTransferredPendingVerification == true
            }
        }
        let hasFailedOutcome = outcomes.values.contains { destinationOutcomes in
            destinationOutcomes.values.contains { outcome in
                if case .failed = outcome { return true }
                return false
            }
        }
        var status: TransferStatus = if cancelled {
            .cancelled
        } else if paused, !vetoed, !sourceDead, !hasFailedOutcome {
            .paused
        } else if request.verificationProfile == .fast,
                  !vetoed, !sourceDead, allTransferredPendingVerification {
            .transferredPendingVerification
        } else if vetoed || sourceDead || !allVerified {
            .failed
        } else {
            .verified
        }

        let spoolTarget = request.spoolDirectory.appendingPathComponent(request.shortID, isDirectory: true)
        let roots = (writeToDestinations ? request.destinationRoots : []) + [spoolTarget]
        var locations = await writeAllRecords(status: status, roots: roots, spoolTarget: spoolTarget)
        var evidenceFailure = locations.count != roots.count

        if !evidenceFailure, status == .verified {
            let provisional = makeReport(status: status, manifestLocations: locations)
            var receipts: [MHLWriteReceipt] = []
            do {
                for destination in request.destinationRoots {
                    if let receipt = try MHLHistoryStore.append(
                        report: provisional,
                        destination: destination,
                        fileSystem: fileSystem
                    ) {
                        receipts.append(receipt)
                    }
                }
            } catch {
                for receipt in receipts.reversed() {
                    MHLHistoryStore.rollback(receipt, fileSystem: fileSystem)
                }
                transferIssues.append("Could not write a complete ASC MHL generation: \(describe(error))")
                await hub.log(.error, transferIssues.last ?? "ASC MHL write failed")
                evidenceFailure = true
            }
        }

        if evidenceFailure {
            let failed = roots.filter { !locations.contains($0) }.map(\.path)
            if !failed.isEmpty {
                let issue = "Could not write complete transfer evidence to: " + failed.joined(separator: ", ")
                transferIssues.append(issue)
                await hub.log(.error, issue)
            }
            if status == .verified || status == .transferredPendingVerification || status == .paused {
                status = .failed
            }

            // Records are generated by this transfer and carry its unique ID;
            // remove the first-pass set so no stale VERIFIED record survives a
            // transfer-level evidence failure, then rewrite the honest verdict.
            cleanupGeneratedRecords(at: roots)
            locations = await writeAllRecords(status: status, roots: roots, spoolTarget: spoolTarget)
        }

        let report = makeReport(status: status, manifestLocations: locations)
        await hub.phase(.done)
        switch status {
        case .paused where request.verificationProfile == .fast:
            // Fast never reads a copy back; its completed files are pending.
            await hub.log(.warning, "Transfer paused safely; completed files were transferred and recorded " +
                "but still need independent verification")
        case .paused:
            await hub.log(.warning, "Transfer paused safely; completed files were verified and recorded")
        case .transferredPendingVerification:
            await hub.log(.warning, "Transfer complete; independent destination verification is still required")
        case .verified:
            await hub.log(.info, "Transfer verified: \(report.verifiedCount) of \(report.verifiedCount) copies passed")
        case .failed:
            await hub.log(.error, "Transfer FAILED: \(report.failedCount) failed, \(report.skippedCount) skipped, \(report.verifiedCount) verified")
        case .cancelled:
            await hub.log(.warning, "Transfer cancelled: \(report.verifiedCount) verified before cancellation")
        }
        await hub.finished(report)
    }

    private func writeAllRecords(
        status: TransferStatus,
        roots: [URL],
        spoolTarget: URL
    ) async -> [URL] {
        let provisional = makeReport(status: status, manifestLocations: [])
        let manifest = TransferManifest(report: provisional)
        guard let json = try? ManifestWriter.jsonData(for: manifest) else {
            await hub.log(.error, "Could not encode the transfer manifest")
            return []
        }
        let markdown = MarkdownReportWriter.markdown(for: manifest)
        var locations: [URL] = []
        for root in roots {
            let isSpool = root == spoolTarget
            if await writeRecords(
                json: json,
                markdown: markdown,
                to: root,
                createFirst: isSpool
            ) {
                locations.append(root)
            }
        }
        return locations
    }

    private func writeRecords(json: Data, markdown: String, to root: URL, createFirst: Bool) async -> Bool {
        var written: [URL] = []
        do {
            if createFirst { try fileSystem.createDirectory(at: root) }
            let manifestURL = root.appendingPathComponent(
                ManifestWriter.manifestFileName(shortID: request.shortID))
            try writeFile(Array(json), to: manifestURL)
            written.append(manifestURL)
            let reportURL = root.appendingPathComponent(
                ManifestWriter.reportFileName(shortID: request.shortID))
            try writeFile(Array(markdown.utf8), to: reportURL)
            written.append(reportURL)
            return true
        } catch {
            for url in written { try? fileSystem.removeItem(at: url) }
            await hub.log(.error, "Could not write manifest to \(root.path): \(describe(error))")
            return false
        }
    }

    private func writeFile(_ bytes: [UInt8], to url: URL) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(
            ".doppelganger-partial-\(request.shortID)-\(url.lastPathComponent)"
        )
        let stream = try fileSystem.openForWritingExclusive(staging)
        do {
            try stream.write(bytes, count: bytes.count)
            try stream.close()
            try fileSystem.moveItemExclusive(from: staging, to: url)
        } catch {
            try? fileSystem.removeItem(at: staging)
            throw error
        }
    }

    private func cleanupGeneratedRecords(at roots: [URL]) {
        for root in roots {
            for name in [
                ManifestWriter.manifestFileName(shortID: request.shortID),
                ManifestWriter.reportFileName(shortID: request.shortID),
                MHLWriter.fileName(shortID: request.shortID),
            ] {
                let url = root.appendingPathComponent(name)
                if fileSystem.fileExists(at: url) { try? fileSystem.removeItem(at: url) }
            }
        }
    }

    private func makeReport(status: TransferStatus, manifestLocations: [URL]) -> TransferReport {
        TransferReport(
            id: request.id,
            status: status,
            algorithm: request.algorithm,
            verificationProfile: request.verificationProfile,
            taskID: request.taskID,
            operatorSnapshot: request.operatorSnapshot,
            projectID: request.projectID,
            sourceFingerprint: request.sourceFingerprint,
            sourceRoot: request.sourceRoot,
            destinations: request.destinationRoots,
            startedAt: startedAt,
            finishedAt: Date(),
            items: items.map { item in
                ItemResult(
                    item: item,
                    sourceDigest: digests[item.relativePath],
                    outcomes: outcomes[item.relativePath] ?? [:]
                )
            },
            manifestLocations: manifestLocations,
            issues: transferIssues
        )
    }

    // MARK: - Helpers

    private mutating func record(_ relativePath: String, _ destination: URL, _ outcome: ItemDestinationOutcome) async {
        outcomes[relativePath, default: [:]][destination] = outcome
        await hub.outcome(relativePath, destination: destination, outcome)
    }

    private func writeFailureReason(_ error: Error) -> ItemFailureReason {
        switch error {
        case FileSystemError.noSpace: .destinationFull
        case FileSystemError.volumeGone: .destinationUnmounted
        case FileSystemError.alreadyExists: .nameCollision
        case FileSystemError.notReadable(let detail): .writeFailed(detail: detail)
        case FileSystemError.sourceChanged: .sourceChanged
        case FileSystemError.other(_, let detail): .writeFailed(detail: detail)
        default: .writeFailed(detail: String(describing: error))
        }
    }

    private static func verifyFailureReason(_ error: Error) -> ItemFailureReason {
        switch error {
        case FileSystemError.volumeGone: .destinationUnmounted
        case FileSystemError.notReadable(let detail): .writeFailed(detail: "verify read failed: \(detail)")
        case FileSystemError.sourceChanged: .sourceChanged
        case FileSystemError.other(_, let detail): .writeFailed(detail: "verify read failed: \(detail)")
        default: .writeFailed(detail: "verify read failed: \(String(describing: error))")
        }
    }

    private func describe(_ error: Error) -> String {
        if let fsError = error as? FileSystemError {
            switch fsError {
            case .noSpace: return "no space left on device"
            case .volumeGone: return "volume or file disappeared"
            case .notReadable(let detail): return detail
            case .alreadyExists: return "file already exists"
            case .sourceChanged: return "source changed during transfer"
            case .other(let code, let detail): return "\(detail) (errno \(code))"
            }
        }
        return String(describing: error)
    }
}
