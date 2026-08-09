import Foundation

/// One requested destination: the user-selected base plus the new task folder
/// that will contain this transfer. Keeping both makes capacity/volume checks
/// possible before the output folder exists.
public struct TransferDestination: Sendable, Hashable {
    public let baseRoot: URL
    public let outputRoot: URL

    public init(baseRoot: URL, outputRoot: URL) {
        self.baseRoot = baseRoot
        self.outputRoot = outputRoot
    }
}

/// Everything the engine needs to run one transfer. The unit the user starts,
/// watches, and trusts.
public struct TransferRequest: Sendable {
    public let id: UUID
    /// Read-only for the entire lifetime of the transfer. No code path may
    /// write, move, or delete anything beneath it.
    public let sourceRoot: URL
    /// One or more; every one must independently pass verification for the
    /// transfer to succeed.
    public let destinations: [TransferDestination]
    public let algorithm: ChecksumAlgorithm
    /// App-side directory that always receives a copy of the manifest, report,
    /// and log — even when every destination is unreachable.
    public let spoolDirectory: URL
    /// Same-volume copies are useful for synthetic/local demos but are not
    /// independent backups. The UI must surface and explicitly acknowledge it.
    public let allowSameVolume: Bool
    /// New offloads require a fresh task folder. Engine tests and explicit
    /// legacy/folder workflows may opt out while retaining collision safety.
    public let requireNewOutputRoots: Bool

    public var destinationRoots: [URL] { destinations.map(\.outputRoot) }

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinationRoots: [URL],
        algorithm: ChecksumAlgorithm = .xxh64,
        spoolDirectory: URL,
        allowSameVolume: Bool = false,
        requireNewOutputRoots: Bool = false
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinations = destinationRoots.map { TransferDestination(baseRoot: $0, outputRoot: $0) }
        self.algorithm = algorithm
        self.spoolDirectory = spoolDirectory
        self.allowSameVolume = allowSameVolume
        self.requireNewOutputRoots = requireNewOutputRoots
    }

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinations: [TransferDestination],
        algorithm: ChecksumAlgorithm = .xxh64,
        spoolDirectory: URL,
        allowSameVolume: Bool = false,
        requireNewOutputRoots: Bool = true
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinations = destinations
        self.algorithm = algorithm
        self.spoolDirectory = spoolDirectory
        self.allowSameVolume = allowSameVolume
        self.requireNewOutputRoots = requireNewOutputRoots
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
