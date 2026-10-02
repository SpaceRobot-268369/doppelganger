import Foundation

/// Stable-enough identity and capacity information for the volume containing a
/// path. A path alone is not proof that two destinations are independent disks.
public struct FileSystemVolume: Sendable, Hashable, Codable {
    public let identifier: String
    public let name: String
    public let mountPath: String
    public let fileSystem: String?
    public let availableBytes: Int64?
    public let totalBytes: Int64?
    public let isRemovable: Bool
    public let isReadOnly: Bool
    public let supportsCaseSensitiveNames: Bool?
    public let maximumNameBytes: Int?
    public let maximumPathBytes: Int?
    /// The physical failure domain behind this volume, used only to decide
    /// whether copies are independent: `disk:<bsd>@<registry id>` for the
    /// whole physical disk an APFS container or partition lives on, or
    /// `net:<server>` for a network share. Volumes with different
    /// `identifier`s can share it — two APFS volumes or partitions on one
    /// disk, two shares from one server. `nil` when the platform could not
    /// establish it; independence checks then treat the volume as unproven,
    /// never as independent. Valid for this boot only; never persist it.
    public let physicalDeviceIdentifier: String?

    public init(
        identifier: String,
        name: String,
        mountPath: String,
        fileSystem: String? = nil,
        availableBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        isRemovable: Bool = false,
        isReadOnly: Bool = false,
        supportsCaseSensitiveNames: Bool? = nil,
        maximumNameBytes: Int? = nil,
        maximumPathBytes: Int? = nil,
        physicalDeviceIdentifier: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.mountPath = mountPath
        self.fileSystem = fileSystem
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.supportsCaseSensitiveNames = supportsCaseSensitiveNames
        self.maximumNameBytes = maximumNameBytes
        self.maximumPathBytes = maximumPathBytes
        self.physicalDeviceIdentifier = physicalDeviceIdentifier
    }
}

/// Core's only window onto storage. Platform implements it with real POSIX
/// I/O; tests implement or decorate it with scratch-directory fakes and fault
/// injection. Core never touches `FileManager` directly.
public protocol FileSystemAccess: Sendable {
    /// Recursively list regular files under `root`, relative paths preserved,
    /// in a deterministic sorted order. Must never mutate anything beneath
    /// `root` — the source stays read-only, `.DS_Store` included. Symbolic
    /// links are not media and are not followed outside `root`. Never
    /// returns a partial list: if any part of the tree outside known
    /// operating-system metadata cannot be read, throw
    /// `FileSystemError.notReadable` (or `.volumeGone` if the root itself
    /// vanished). Preflight, the engine plan and the post-transfer rescan
    /// treat the result as the complete source.
    func enumerate(root: URL) throws -> [SourceItem]

    /// Resolve aliases/symlinks for safety comparisons. For a not-yet-created
    /// output path, implementations resolve the nearest existing ancestor.
    func canonicalURL(_ url: URL) -> URL

    /// Identity of the physical/logical mounted volume containing `url`.
    func volume(at url: URL) throws -> FileSystemVolume

    /// Current size and modification time for one regular source file.
    func sourceItem(at url: URL, relativeTo root: URL) throws -> SourceItem

    func fileExists(at url: URL) -> Bool

    /// Create a directory, with intermediates, succeeding if it exists.
    func createDirectory(at url: URL) throws

    /// Open for reading. `uncached` asks the OS to bypass the buffer cache so
    /// verification re-reads come from disk, not from the write-back cache.
    func openForReading(_ url: URL, uncached: Bool) throws -> any FileReadStream

    /// Open a brand-new file for writing (exclusive create). An existing file
    /// throws `FileSystemError.alreadyExists` — the engine's name collision.
    func openForWritingExclusive(_ url: URL) throws -> any FileWriteStream

    /// Atomically publish a fully flushed staging file without overwriting an
    /// existing final path.
    func moveItemExclusive(from staging: URL, to final: URL) throws

    /// Atomically replace one generated mutable index after its prior bytes
    /// have been archived. Transfer media and immutable evidence never use
    /// this operation; it exists for `ascmhl_chain.xml` generation updates.
    func replaceGeneratedIndexAtomically(from staging: URL, to final: URL) throws

    /// Preserve source timestamps on a newly published destination file so a
    /// copied card retains a stable source-plan identity for later cascades.
    func setModificationTime(_ timeIntervalSince1970: TimeInterval, at url: URL) throws

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
