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
    public let verificationProfile: VerificationProfile
    public let taskID: UUID
    public let operatorSnapshot: OperatorSnapshot?
    public let projectID: UUID?
    public let sourceFingerprint: String?
    /// App-side directory that always receives a copy of the manifest, report,
    /// and log — even when every destination is unreachable.
    public let spoolDirectory: URL
    /// Same-volume copies are useful for synthetic/local demos but are not
    /// independent backups. The UI must surface and explicitly acknowledge it.
    public let allowSameVolume: Bool
    /// New offloads require a fresh task folder. Engine tests and explicit
    /// legacy/folder workflows may opt out while retaining collision safety.
    public let requireNewOutputRoots: Bool
    /// A prior paused attempt whose verified pairs may be reused after the
    /// source plan and destination metadata are revalidated.
    public let resumeManifest: TransferManifest?
    /// A prior failed attempt that authorizes replacing only explicitly
    /// selected, non-verified destination pairs. Existing failed bytes are
    /// quarantined rather than overwritten.
    public let retryManifest: TransferManifest?
    /// Optional whole-file subset used by a fine-grained retry. A retry
    /// session addresses one destination, so this set is its exact scope.
    public let includedRelativePaths: Set<String>?
    /// Existing-output candidates keyed by canonical output path. They permit
    /// a no-write skip only after the engine independently hashes both sides.
    public let duplicateManifests: [String: TransferManifest]

    public var destinationRoots: [URL] { destinations.map(\.outputRoot) }

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinationRoots: [URL],
        algorithm: ChecksumAlgorithm = .xxh3,
        verificationProfile: VerificationProfile = .standard,
        taskID: UUID? = nil,
        operatorSnapshot: OperatorSnapshot? = nil,
        projectID: UUID? = nil,
        sourceFingerprint: String? = nil,
        spoolDirectory: URL,
        allowSameVolume: Bool = false,
        requireNewOutputRoots: Bool = false,
        resumeManifest: TransferManifest? = nil,
        retryManifest: TransferManifest? = nil,
        includedRelativePaths: Set<String>? = nil,
        duplicateManifests: [String: TransferManifest] = [:]
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinations = destinationRoots.map { TransferDestination(baseRoot: $0, outputRoot: $0) }
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.taskID = taskID ?? id
        self.operatorSnapshot = operatorSnapshot
        self.projectID = projectID
        self.sourceFingerprint = sourceFingerprint
        self.spoolDirectory = spoolDirectory
        self.allowSameVolume = allowSameVolume
        self.requireNewOutputRoots = requireNewOutputRoots
        self.resumeManifest = resumeManifest
        self.retryManifest = retryManifest
        self.includedRelativePaths = includedRelativePaths
        self.duplicateManifests = duplicateManifests
    }

    public init(
        id: UUID = UUID(),
        sourceRoot: URL,
        destinations: [TransferDestination],
        algorithm: ChecksumAlgorithm = .xxh3,
        verificationProfile: VerificationProfile = .standard,
        taskID: UUID? = nil,
        operatorSnapshot: OperatorSnapshot? = nil,
        projectID: UUID? = nil,
        sourceFingerprint: String? = nil,
        spoolDirectory: URL,
        allowSameVolume: Bool = false,
        requireNewOutputRoots: Bool = true,
        resumeManifest: TransferManifest? = nil,
        retryManifest: TransferManifest? = nil,
        includedRelativePaths: Set<String>? = nil,
        duplicateManifests: [String: TransferManifest] = [:]
    ) {
        self.id = id
        self.sourceRoot = sourceRoot
        self.destinations = destinations
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.taskID = taskID ?? id
        self.operatorSnapshot = operatorSnapshot
        self.projectID = projectID
        self.sourceFingerprint = sourceFingerprint
        self.spoolDirectory = spoolDirectory
        self.allowSameVolume = allowSameVolume
        self.requireNewOutputRoots = requireNewOutputRoots
        self.resumeManifest = resumeManifest
        self.retryManifest = retryManifest
        self.includedRelativePaths = includedRelativePaths
        self.duplicateManifests = duplicateManifests
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
