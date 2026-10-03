import Foundation
@testable import Doppelganger

/// Decorates a real `FileSystemAccess` with injectable faults so the failure
/// modes from `offload-model.md` can be produced deterministically against
/// scratch fixtures: corrupted destination bytes, ENOSPC mid-copy, volumes
/// vanishing mid-transfer, unreadable source files.
final class FailpointFileSystem: FileSystemAccess, @unchecked Sendable {
    private let base: any FileSystemAccess
    private let lock = NSLock()
    private var volumeOverrides: [String: FileSystemVolume] = [:]  // canonical root path → reported volume

    // Failpoint state, lock-guarded.
    private var corruptOnWriteSuffixes: Set<String> = []
    private var noSpaceBudgets: [String: Int] = [:]        // root path → writable bytes before ENOSPC
    private var goneRoots: Set<String> = []                // everything under these fails volumeGone
    private var listingBudgets: [String: Int] = [:]        // root path → listings of it before enumerate fails volumeGone
    private var goneAfterReadBudgets: [String: Int] = [:]  // root path → readable bytes before the volume "vanishes"
    private var goneAfterWriteBudgets: [String: Int] = [:] // root path → writable bytes before the volume "vanishes"
    private var unreadableSuffixes: Set<String> = []
    private struct InjectedReadError {
        let afterBytes: Int
        var failingOpens: Int
    }
    private struct ArmedReadError {
        let limit: Int
        var bytesRead: Int
    }
    private var readErrorSpecs: [String: InjectedReadError] = [:] // path suffix → mid-file read error to inject
    private var armedReadErrors: [String: ArmedReadError] = [:]   // open path → bytes allowed before it fires
    private var changedSourceSuffixes: Set<String> = []
    private var freeSpaceOverrides: [String: Int64] = [:]
    private var evidenceWriteFailureRoots: Set<String> = []
    private var modificationTimeFailureSuffixes: Set<String> = []
    private var durabilityByPath: [String: WriteDurability] = [:]  // logical target path → requested durability
    private var readDelayMicros: UInt32 = 0
    private var writeDelayMicros: UInt32 = 0

    init(base: any FileSystemAccess) {
        self.base = base
    }

    // MARK: - Test controls

    /// Flip the first byte of the first chunk written to any path with this
    /// suffix — produces a checksum mismatch on read-back at exactly one file.
    func corruptFirstByteOnWrite(pathSuffix: String) {
        _ = withLock { corruptOnWriteSuffixes.insert(pathSuffix) }
    }

    /// Writes under `root` throw `.noSpace` once `bytes` have been written.
    func failWithNoSpace(under root: URL, afterBytes bytes: Int) {
        withLock { noSpaceBudgets[root.path] = bytes }
    }

    /// Everything under `root` immediately fails with `.volumeGone`, and
    /// `fileExists` under it reports false — an unmounted volume.
    func markVolumeGone(_ root: URL) {
        withLock { _ = goneRoots.insert(root.path) }
    }

    /// The first `count` listings of exactly `root` succeed; every later one
    /// throws `.volumeGone` — a card pulled after the engine planned from it,
    /// which only the post-copy source re-scan notices. Reads, writes, and
    /// metadata under `root` are unaffected.
    func failListings(of root: URL, after count: Int) {
        withLock { listingBudgets[root.path] = count }
    }

    /// The volume at `root` "vanishes" after `bytes` have been read under it.
    func markVolumeGoneAfterReading(bytes: Int, under root: URL) {
        withLock { goneAfterReadBudgets[root.path] = bytes }
    }

    /// The volume at `root` "vanishes" after `bytes` have been written under it.
    func markVolumeGoneAfterWriting(bytes: Int, under root: URL) {
        withLock { goneAfterWriteBudgets[root.path] = bytes }
    }

    /// Opening any path with this suffix for reading throws `.notReadable`.
    func markUnreadable(pathSuffix: String) {
        _ = withLock { unreadableSuffixes.insert(pathSuffix) }
    }

    /// Reads of any path with this suffix throw `.notReadable` (what a real
    /// EIO on read maps to in `IOContext.reading`) once `afterBytes` bytes have
    /// come through that open stream: a bad sector past the first byte, which
    /// preflight's first-byte probe cannot see. Only the next `failingOpens`
    /// opens are armed; later opens read cleanly, like a marginal sector that
    /// succeeds on a re-read.
    func injectReadError(pathSuffix: String, afterBytes: Int, failingOpens: Int = .max) {
        withLock { readErrorSpecs[pathSuffix] = InjectedReadError(afterBytes: afterBytes, failingOpens: failingOpens) }
    }

    func markSourceChanged(pathSuffix: String) {
        _ = withLock { changedSourceSuffixes.insert(pathSuffix) }
    }

    func overrideFreeSpace(at root: URL, bytes: Int64) {
        withLock { freeSpaceOverrides[root.path] = bytes }
    }

    /// Report `volume` for everything at or under `root`. Stands in for disk
    /// layouts no test machine has: two APFS volumes or partitions on one
    /// disk, two shares on one server, a device the platform cannot name.
    func overrideVolume(at root: URL, with volume: FileSystemVolume) {
        let key = base.canonicalURL(root).path
        withLock { volumeOverrides[key] = volume }
    }

    func failEvidenceWrites(under root: URL) {
        _ = withLock { evidenceWriteFailureRoots.insert(root.path) }
    }

    /// `setModificationTime` on any path with this suffix throws — the
    /// exFAT/SMB mount that publishes bytes but refuses a timestamp.
    func failModificationTime(pathSuffix: String) {
        _ = withLock { modificationTimeFailureSuffixes.insert(pathSuffix) }
    }

    /// The `WriteDurability` the engine asked for when it opened the file
    /// that eventually published at `url` (staging names are folded back to
    /// their logical target), or `nil` if it was never opened.
    func requestedDurability(for url: URL) -> WriteDurability? {
        withLock { durabilityByPath[url.path] }
    }

    /// Slow every chunk down so cancellation tests have a deterministic
    /// mid-transfer window to land in.
    func delayReads(microseconds: UInt32) {
        withLock { readDelayMicros = microseconds }
    }

    func delayWrites(microseconds: UInt32) {
        withLock { writeDelayMicros = microseconds }
    }

    // MARK: - FileSystemAccess

    func enumerate(root: URL) throws -> [SourceItem] {
        if isGone(root.path) { throw FileSystemError.volumeGone }
        try withLock {
            guard let remaining = listingBudgets[root.path] else { return }
            if remaining <= 0 { throw FileSystemError.volumeGone }
            listingBudgets[root.path] = remaining - 1
        }
        return try base.enumerate(root: root)
    }

    func canonicalURL(_ url: URL) -> URL { base.canonicalURL(url) }

    func volume(at url: URL) throws -> FileSystemVolume {
        let path = base.canonicalURL(url).path
        let override = withLock {
            volumeOverrides.filter { covered(path, by: $0.key) }.max { $0.key.count < $1.key.count }?.value
        }
        return try override ?? base.volume(at: url)
    }

    func sourceItem(at url: URL, relativeTo root: URL) throws -> SourceItem {
        if isGone(url.path) { throw FileSystemError.volumeGone }
        let item = try base.sourceItem(at: url, relativeTo: root)
        if withLock({ changedSourceSuffixes.contains { url.path.hasSuffix($0) } }) {
            return SourceItem(
                relativePath: item.relativePath,
                size: item.size + 1,
                modificationTime: item.modificationTime
            )
        }
        return item
    }

    func fileExists(at url: URL) -> Bool {
        if isGone(url.path) { return false }
        return base.fileExists(at: url)
    }

    func createDirectory(at url: URL) throws {
        if isGone(url.path) { throw FileSystemError.volumeGone }
        try base.createDirectory(at: url)
    }

    func openForReading(_ url: URL, uncached: Bool) throws -> any FileReadStream {
        let path = url.path
        if isGone(path) { throw FileSystemError.volumeGone }
        if withLock({ unreadableSuffixes.contains { path.hasSuffix($0) } }) {
            throw FileSystemError.notReadable(detail: "\(path): injected unreadable file")
        }
        withLock {
            armedReadErrors[path] = nil
            if let suffix = readErrorSpecs.keys.first(where: { path.hasSuffix($0) }),
               let spec = readErrorSpecs[suffix], spec.failingOpens > 0 {
                readErrorSpecs[suffix]?.failingOpens -= 1
                armedReadErrors[path] = ArmedReadError(limit: spec.afterBytes, bytesRead: 0)
            }
        }
        return FailpointReadStream(base: try base.openForReading(url, uncached: uncached), path: path, owner: self)
    }

    func openForWritingExclusive(_ url: URL, durability: WriteDurability) throws -> any FileWriteStream {
        let path = url.path
        if isGone(path) { throw FileSystemError.volumeGone }
        let logicalPath = logicalTargetPath(for: path)
        withLock { durabilityByPath[logicalPath] = durability }
        if withLock({ evidenceWriteFailureRoots.contains { covered(path, by: $0) } }),
           URL(fileURLWithPath: logicalPath).lastPathComponent.hasPrefix("doppelganger-") {
            throw FileSystemError.noSpace
        }
        let corrupt = withLock { () -> Bool in
            if let suffix = corruptOnWriteSuffixes.first(where: {
                path.hasSuffix($0) || logicalPath.hasSuffix($0)
            }) {
                corruptOnWriteSuffixes.remove(suffix)
                return true
            }
            return false
        }
        return FailpointWriteStream(
            base: try base.openForWritingExclusive(url, durability: durability),
            path: path,
            owner: self,
            corruptFirstByte: corrupt
        )
    }

    func moveItemExclusive(from staging: URL, to final: URL) throws {
        if isGone(staging.path) || isGone(final.path) { throw FileSystemError.volumeGone }
        try base.moveItemExclusive(from: staging, to: final)
    }

    func replaceGeneratedIndexAtomically(from staging: URL, to final: URL) throws {
        if isGone(staging.path) || isGone(final.path) { throw FileSystemError.volumeGone }
        try base.replaceGeneratedIndexAtomically(from: staging, to: final)
    }

    func setModificationTime(_ timeIntervalSince1970: TimeInterval, at url: URL) throws {
        if isGone(url.path) { throw FileSystemError.volumeGone }
        if withLock({ modificationTimeFailureSuffixes.contains { url.path.hasSuffix($0) } }) {
            throw FileSystemError.other(code: EPERM, detail: "\(url.path): injected timestamp refusal")
        }
        try base.setModificationTime(timeIntervalSince1970, at: url)
    }

    func removeItem(at url: URL) throws {
        if isGone(url.path) { throw FileSystemError.volumeGone }
        try base.removeItem(at: url)
    }

    func freeSpace(at url: URL) throws -> Int64 {
        if isGone(url.path) { throw FileSystemError.volumeGone }
        if let override = withLock({ freeSpaceOverrides.first { url.path.hasPrefix($0.key) }?.value }) {
            return override
        }
        return try base.freeSpace(at: url)
    }

    // MARK: - Stream callbacks

    fileprivate func beforeRead(path: String) throws {
        let delay = withLock { readDelayMicros }
        if delay > 0 { usleep(delay) }
        if isGone(path) { throw FileSystemError.volumeGone }
        if let armed = withLock({ armedReadErrors[path] }), armed.bytesRead >= armed.limit {
            throw FileSystemError.notReadable(
                detail: "\(path): injected read error (EIO) after \(armed.limit) bytes"
            )
        }
    }

    fileprivate func afterRead(path: String, count: Int) {
        withLock {
            armedReadErrors[path]?.bytesRead += count
            for (root, budget) in goneAfterReadBudgets where covered(path, by: root) {
                let remaining = budget - count
                goneAfterReadBudgets[root] = remaining
                if remaining <= 0 { goneRoots.insert(root) }
            }
        }
    }

    fileprivate func beforeWrite(path: String, count: Int) throws {
        let delay = withLock { writeDelayMicros }
        if delay > 0, count > 0 { usleep(delay) }
        if isGone(path) { throw FileSystemError.volumeGone }
        try withLock {
            for (root, budget) in noSpaceBudgets where covered(path, by: root) {
                if budget < count { throw FileSystemError.noSpace }
                noSpaceBudgets[root] = budget - count
            }
        }
    }

    fileprivate func afterWrite(path: String, count: Int) {
        withLock {
            for (root, budget) in goneAfterWriteBudgets where covered(path, by: root) {
                let remaining = budget - count
                goneAfterWriteBudgets[root] = remaining
                if remaining <= 0 { goneRoots.insert(root) }
            }
        }
    }

    // MARK: - Internals

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func covered(_ path: String, by root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    /// Production writes through `.doppelganger-partial-<id>-<name>` and then
    /// atomically publishes the file. Fault controls still target the final
    /// logical filename so tests exercise that production path.
    private func logicalTargetPath(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let marker = ".doppelganger-partial-"
        guard name.hasPrefix(marker) else { return path }
        let remainder = name.dropFirst(marker.count)
        guard remainder.count > 9 else { return path }
        let originalName = remainder.dropFirst(9) // eight-char ID plus '-'
        return url.deletingLastPathComponent().appendingPathComponent(String(originalName)).path
    }

    private func isGone(_ path: String) -> Bool {
        withLock { goneRoots.contains { covered(path, by: $0) } }
    }
}

private final class FailpointReadStream: FileReadStream {
    private let base: any FileReadStream
    private let path: String
    private let owner: FailpointFileSystem

    init(base: any FileReadStream, path: String, owner: FailpointFileSystem) {
        self.base = base
        self.path = path
        self.owner = owner
    }

    func read(into buffer: inout [UInt8]) throws -> Int {
        try owner.beforeRead(path: path)
        let count = try base.read(into: &buffer)
        owner.afterRead(path: path, count: count)
        return count
    }

    func close() {
        base.close()
    }
}

private final class FailpointWriteStream: FileWriteStream {
    private let base: any FileWriteStream
    private let path: String
    private let owner: FailpointFileSystem
    private var corruptFirstByte: Bool

    init(base: any FileWriteStream, path: String, owner: FailpointFileSystem, corruptFirstByte: Bool) {
        self.base = base
        self.path = path
        self.owner = owner
        self.corruptFirstByte = corruptFirstByte
    }

    func write(_ buffer: [UInt8], count: Int) throws {
        try owner.beforeWrite(path: path, count: count)
        if corruptFirstByte, count > 0 {
            corruptFirstByte = false
            var mutated = buffer
            mutated[0] ^= 0xFF
            try base.write(mutated, count: count)
        } else {
            try base.write(buffer, count: count)
        }
        owner.afterWrite(path: path, count: count)
    }

    func close() throws {
        try owner.beforeWrite(path: path, count: 0)
        try base.close()
    }
}
