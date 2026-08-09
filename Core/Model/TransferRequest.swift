import Foundation

/// Everything the engine needs to run one transfer. The unit the user starts,
/// watches, and trusts.
public struct TransferRequest: Sendable {
    public let id: UUID
    /// Read-only for the entire lifetime of the transfer. No code path may
    /// write, move, or delete anything beneath it.
    public let sourceRoot: URL
    /// One or more; every one must independently pass verification for the
    /// transfer to succeed.
    public let destinationRoots: [URL]
    public let algorithm: ChecksumAlgorithm
    /// App-side directory that always receives a copy of the manifest, report,
    /// and log — even when every destination is unreachable.
    public let spoolDirectory: URL

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinationRoots: [URL],
        algorithm: ChecksumAlgorithm = .xxh64,
        spoolDirectory: URL
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinationRoots = destinationRoots
        self.algorithm = algorithm
        self.spoolDirectory = spoolDirectory
    }

    /// Stable short identifier used in generated file names.
    public var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }
}

/// Engine tuning knobs. Tests shrink the chunk size so multi-chunk paths are
/// exercised without large fixtures.
public struct TransferConfiguration: Sendable {
    /// Bounded read/write chunk. Never read a whole media file into memory.
    public var chunkSize: Int
    /// Minimum interval between `.progress` events.
    public var progressInterval: Duration

    public init(chunkSize: Int = 8 * 1024 * 1024, progressInterval: Duration = .milliseconds(100)) {
        self.chunkSize = chunkSize
        self.progressInterval = progressInterval
    }
}
