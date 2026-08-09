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

        await preflightDestinations(totalBytes: totalBytes)
        await copyPass()
        await verifyPass()
        await finish(writeToDestinations: true)
    }

    // MARK: - Validation & preflight

    private func validateRequest() -> String? {
        guard !request.destinationRoots.isEmpty else { return "No destinations selected." }
        let sourcePath = request.sourceRoot.standardizedFileURL.path
        var seen = Set<String>()
        for destination in request.destinationRoots {
            let destPath = destination.standardizedFileURL.path
            guard seen.insert(destPath).inserted else {
                return "Duplicate destination: \(destPath)"
            }
            if destPath == sourcePath || destPath.hasPrefix(sourcePath + "/") {
                return "Destination \(destPath) is inside the source. The source stays read-only; refusing to start."
            }
            if sourcePath.hasPrefix(destPath + "/") {
                return "Source is inside destination \(destPath); refusing to start."
            }
        }
        return nil
    }

    private mutating func preflightDestinations(totalBytes: Int64) async {
        for destination in request.destinationRoots {
            guard fileSystem.fileExists(at: destination) else {
                await failWholeDestination(destination, reason: .destinationUnmounted,
                                           log: "Destination \(destination.path) is not mounted")
                continue
            }
            if let free = try? fileSystem.freeSpace(at: destination), free < totalBytes {
                await failWholeDestination(destination, reason: .destinationFull,
                                           log: "Destination \(destination.path) has " +
                                           "\(MarkdownReportWriter.byteString(free)) free, needs " +
                                           MarkdownReportWriter.byteString(totalBytes))
            }
        }
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
        let stream: any FileWriteStream
    }

    private mutating func copy(_ item: SourceItem) async {
        let liveDestinations = request.destinationRoots.filter { !deadDestinations.contains($0) }
        guard !liveDestinations.isEmpty else { return }

        var writers: [DestinationWriter] = []
        for destination in liveDestinations {
            let target = destination.appendingPathComponent(item.relativePath)
            do {
                try fileSystem.createDirectory(at: target.deletingLastPathComponent())
                let stream = try fileSystem.openForWritingExclusive(target)
                writers.append(DestinationWriter(destination: destination, target: target, stream: stream))
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
                try? fileSystem.removeItem(at: writer.target)
            }
            await sourceReadFailed(item, error: error)
            return
        }
        defer { reader.close() }

        var hasher = request.algorithm.makeHasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        var failedHere = Set<URL>()

        while true {
            if Task.isCancelled {
                cancelled = true
                for writer in writers where !failedHere.contains(writer.destination) {
                    try? writer.stream.close()
                    try? fileSystem.removeItem(at: writer.target)
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
                    try? fileSystem.removeItem(at: writer.target)
                }
                await sourceReadFailed(item, error: error)
                return
            }
            if count == 0 { break }

            buffer.withUnsafeBytes { raw in
                hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }

            for writer in writers where !failedHere.contains(writer.destination) {
                do {
                    try writer.stream.write(buffer, count: count)
                } catch {
                    failedHere.insert(writer.destination)
                    try? fileSystem.removeItem(at: writer.target)
                    await destinationFailed(writer.destination, item: item, error: error)
                }
            }
            if failedHere.count == writers.count { return }
            await hub.addCopiedBytes(count)
        }

        let digest = hasher.hexDigest()
        digests[item.relativePath] = digest

        for writer in writers where !failedHere.contains(writer.destination) {
            do {
                try writer.stream.close()
                pendingVerify[writer.destination, default: []].append((item, digest))
                pendingPaths[writer.destination, default: []].insert(item.relativePath)
            } catch {
                try? fileSystem.removeItem(at: writer.target)
                await destinationFailed(writer.destination, item: item, error: error)
            }
        }
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
        let status: TransferStatus = if cancelled {
            .cancelled
        } else if vetoed || sourceDead || !allVerified {
            .failed
        } else {
            .verified
        }

        let provisional = makeReport(status: status, manifestLocations: [])
        let manifest = TransferManifest(report: provisional)
        let json = try? ManifestWriter.jsonData(for: manifest)
        let markdown = MarkdownReportWriter.markdown(for: manifest)

        var locations: [URL] = []
        if writeToDestinations {
            for destination in request.destinationRoots {
                if await writeRecords(json: json, markdown: markdown, to: destination, createFirst: false) {
                    locations.append(destination)
                }
            }
        }
        let spoolTarget = request.spoolDirectory.appendingPathComponent(request.shortID, isDirectory: true)
        if await writeRecords(json: json, markdown: markdown, to: spoolTarget, createFirst: true) {
            locations.append(spoolTarget)
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

    private func writeRecords(json: Data?, markdown: String, to root: URL, createFirst: Bool) async -> Bool {
        do {
            if createFirst { try fileSystem.createDirectory(at: root) }
            if let json {
                try writeFile(Array(json), to: root.appendingPathComponent(ManifestWriter.manifestFileName(shortID: request.shortID)))
            }
            try writeFile(Array(markdown.utf8), to: root.appendingPathComponent(ManifestWriter.reportFileName(shortID: request.shortID)))
            return true
        } catch {
            await hub.log(.error, "Could not write manifest to \(root.path): \(describe(error))")
            return false
        }
    }

    private func writeFile(_ bytes: [UInt8], to url: URL) throws {
        let stream = try fileSystem.openForWritingExclusive(url)
        do {
            try stream.write(bytes, count: bytes.count)
            try stream.close()
        } catch {
            try? fileSystem.removeItem(at: url)
            throw error
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
            manifestLocations: manifestLocations
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
        case FileSystemError.other(_, let detail): .writeFailed(detail: detail)
        default: .writeFailed(detail: String(describing: error))
        }
    }

    private static func verifyFailureReason(_ error: Error) -> ItemFailureReason {
        switch error {
        case FileSystemError.volumeGone: .destinationUnmounted
        case FileSystemError.notReadable(let detail): .writeFailed(detail: "verify read failed: \(detail)")
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
            case .other(let code, let detail): return "\(detail) (errno \(code))"
            }
        }
        return String(describing: error)
    }
}
