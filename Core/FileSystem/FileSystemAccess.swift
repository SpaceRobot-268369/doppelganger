import Foundation

/// Core's only window onto storage. Platform implements it with real POSIX
/// I/O; tests implement or decorate it with scratch-directory fakes and fault
/// injection. Core never touches `FileManager` directly.
public protocol FileSystemAccess: Sendable {
    /// Recursively list regular files under `root`, relative paths preserved,
    /// in a deterministic sorted order. Must never mutate anything beneath
    /// `root` — the source stays read-only, `.DS_Store` included.
    func enumerate(root: URL) throws -> [SourceItem]

    func fileExists(at url: URL) -> Bool

    /// Create a directory, with intermediates, succeeding if it exists.
    func createDirectory(at url: URL) throws

    /// Open for reading. `uncached` asks the OS to bypass the buffer cache so
    /// verification re-reads come from disk, not from the write-back cache.
    func openForReading(_ url: URL, uncached: Bool) throws -> any FileReadStream

    /// Open a brand-new file for writing (exclusive create). An existing file
    /// throws `FileSystemError.alreadyExists` — the engine's name collision.
    func openForWritingExclusive(_ url: URL) throws -> any FileWriteStream

    /// Remove a single file. The engine only ever calls this to clean up a
    /// partial destination copy — never under a source root.
    func removeItem(at url: URL) throws

    /// Free bytes on the volume containing `url`.
    func freeSpace(at url: URL) throws -> Int64
}

public protocol FileReadStream: AnyObject {
    /// Fill `buffer` from the current offset; returns bytes read, 0 at EOF.
    func read(into buffer: inout [UInt8]) throws -> Int
    func close()
}

public protocol FileWriteStream: AnyObject {
    /// Write the first `count` bytes of `buffer`.
    func write(_ buffer: [UInt8], count: Int) throws
    /// Flush to disk and close; a failed close is a failed write.
    func close() throws
}
