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

    private var items: [SourceItem] = []
    /// relativePath → source digest, computed once during the copy pass.
    private var digests: [String: String] = [:]
    private var outcomes: [String: [URL: ItemDestinationOutcome]] = [:]
    /// Copied-but-not-yet-verified pairs, per destination. Copied is not
    /// success; everything here must still pass the verify pass.
    private var pendingVerify: [URL: [(item: SourceItem, digest: String)]] = [:]
    private var pendingPaths: [URL: Set<String>] = [:]
    private var deadDestinations: Set<URL> = []
    private var sourceDead = false
    private var cancelled = false
    /// The request itself was invalid (e.g. a destination inside the source);
    /// zero items must not read as a vacuous success.
    private var vetoed = false
    private var transferIssues: [String] = []
    private let startedAt = Date()

    init(
        request: TransferRequest,
        configuration: TransferConfiguration,
        fileSystem: any FileSystemAccess,
        hub: ProgressHub
    ) {
        self.request = request
        self.configuration = configuration
        self.fileSystem = fileSystem
        self.hub = hub
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
            await hub.log(.error, "Could not enumerate source: \(describe(error))")
            await finish(writeToDestinations: true)
            return
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
        await copyPass()
        await verifyPass()
        await confirmSourcePlanUnchanged()
        await finish(writeToDestinations: true)
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
        var seenVolumes = Set<String>()
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
                if volume.identifier == sourceVolume.identifier,
                   sourceVolume.isRemovable,
                   source.path == sourceVolume.mountPath {
                    return "A removable source volume cannot also contain its destination."
                }
                if volume.identifier == sourceVolume.identifier, !request.allowSameVolume {
                    return "Source and destination \(base.path) are on the same volume. Explicit acknowledgement is required."
                }
                if !seenVolumes.insert(volume.identifier).inserted, !request.allowSameVolume {
                    return "Two destinations share the same physical volume. Explicit acknowledgement is required."
                }
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
            if request.requireNewOutputRoots, fileSystem.fileExists(at: destination) {
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
            if let free = try? fileSystem.freeSpace(at: requested.baseRoot), free < totalBytes + reserve {
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

    private mutating func copyPass() async {
        await hub.phase(.copying)
        for item in items {
            if Task.isCancelled { cancelled = true }
            if cancelled || sourceDead { break }
            if deadDestinations.count == request.destinationRoots.count { break }
            await hub.beginItem(item.relativePath)
            await copy(item)
            await hub.finishItem()
        }
        if Task.isCancelled { cancelled = true }
        await fillUnattemptedSkips()
    }

    private struct DestinationWriter {
        let destination: URL
        let target: URL
        let staging: URL
        let stream: any FileWriteStream
    }

    private mutating func copy(_ item: SourceItem) async {
        let liveDestinations = request.destinationRoots.filter { !deadDestinations.contains($0) }
        guard !liveDestinations.isEmpty else { return }

        var writers: [DestinationWriter] = []
        for destination in liveDestinations {
            let target = destination.appendingPathComponent(item.relativePath)
            let staging = target.deletingLastPathComponent().appendingPathComponent(
                ".doppelganger-partial-\(request.shortID)-\(target.lastPathComponent)"
            )
            do {
                try fileSystem.createDirectory(at: target.deletingLastPathComponent())
                guard !fileSystem.fileExists(at: target) else { throw FileSystemError.alreadyExists }
                let stream = try fileSystem.openForWritingExclusive(staging)
                writers.append(DestinationWriter(
                    destination: destination, target: target, staging: staging, stream: stream))
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
                try? writer.stream.close()
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceReadFailed(item, error: error)
            return
        }
        defer { reader.close() }

        var hasher = request.algorithm.makeHasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        var failedHere = Set<URL>()
        var bytesRead: Int64 = 0

        while true {
            if Task.isCancelled {
                cancelled = true
                for writer in writers where !failedHere.contains(writer.destination) {
                    try? writer.stream.close()
                    try? fileSystem.removeItem(at: writer.staging)
                    await record(item.relativePath, writer.destination, .failed(.cancelled))
                }
                await hub.log(.warning, "\(item.relativePath): cancelled mid-copy; partial copies removed")
                return
            }

            let count: Int
            do {
                count = try reader.read(into: &buffer)
            } catch {
                for writer in writers where !failedHere.contains(writer.destination) {
                    try? writer.stream.close()
                    try? fileSystem.removeItem(at: writer.staging)
                }
                await sourceReadFailed(item, error: error)
                return
            }
            if count == 0 { break }
            bytesRead += Int64(count)

            buffer.withUnsafeBytes { raw in
                hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }

            for writer in writers where !failedHere.contains(writer.destination) {
                do {
                    try writer.stream.write(buffer, count: count)
                } catch {
                    failedHere.insert(writer.destination)
                    try? writer.stream.close()
                    try? fileSystem.removeItem(at: writer.staging)
                    await destinationFailed(writer.destination, item: item, error: error)
                }
            }
            if failedHere.count == writers.count { return }
            await hub.addCopiedBytes(count)
        }

        guard bytesRead == item.size, sourceStillMatches(item) else {
            for writer in writers where !failedHere.contains(writer.destination) {
                try? writer.stream.close()
                try? fileSystem.removeItem(at: writer.staging)
            }
            await sourceChanged(item)
            return
        }

        let digest = hasher.hexDigest()
        digests[item.relativePath] = digest

        for writer in writers where !failedHere.contains(writer.destination) {
            do {
                try writer.stream.close()
                try fileSystem.moveItemExclusive(from: writer.staging, to: writer.target)
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

    private mutating func confirmSourcePlanUnchanged() async {
        guard !sourceDead, !cancelled else { return }
        guard let current = try? fileSystem.enumerate(root: request.sourceRoot), current == items else {
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
        var status: TransferStatus = if cancelled {
            .cancelled
        } else if vetoed || sourceDead || !allVerified {
            .failed
        } else {
            .verified
        }

        let spoolTarget = request.spoolDirectory.appendingPathComponent(request.shortID, isDirectory: true)
        let roots = (writeToDestinations ? request.destinationRoots : []) + [spoolTarget]
        var locations = await writeAllRecords(status: status, roots: roots, spoolTarget: spoolTarget)

        if locations.count != roots.count {
            let failed = roots.filter { !locations.contains($0) }.map(\.path)
            let issue = "Could not write complete transfer evidence to: " + failed.joined(separator: ", ")
            transferIssues.append(issue)
            await hub.log(.error, issue)
            if status == .verified { status = .failed }

            // Records are generated by this transfer and carry its unique ID;
            // remove the first-pass set so no stale VERIFIED record survives a
            // transfer-level evidence failure, then rewrite the honest verdict.
            cleanupGeneratedRecords(at: roots)
            locations = await writeAllRecords(status: status, roots: roots, spoolTarget: spoolTarget)
        }

        let report = makeReport(status: status, manifestLocations: locations)
        await hub.phase(.done)
        switch status {
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
            let mhl = isSpool ? nil : MHLWriter.xml(for: provisional, destination: root)
            if await writeRecords(
                json: json,
                markdown: markdown,
                mhl: mhl,
                to: root,
                createFirst: isSpool
            ) {
                locations.append(root)
            }
        }
        return locations
    }

    private func writeRecords(json: Data, markdown: String, mhl: String?, to root: URL, createFirst: Bool) async -> Bool {
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
            if let mhl {
                let mhlURL = root.appendingPathComponent(MHLWriter.fileName(shortID: request.shortID))
                try writeFile(Array(mhl.utf8), to: mhlURL)
                written.append(mhlURL)
            }
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
