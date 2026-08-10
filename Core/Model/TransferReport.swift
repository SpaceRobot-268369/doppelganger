import Foundation

/// The full per-item, per-destination result of one transfer.
public struct ItemResult: Sendable, Hashable, Identifiable {
    public let item: SourceItem
    /// Hex digest of the source bytes, computed once during the copy pass.
    /// `nil` when the item was never successfully read (skipped or unreadable).
    public let sourceDigest: String?
    public let outcomes: [URL: ItemDestinationOutcome]

    public var id: String { item.relativePath }

    public init(item: SourceItem, sourceDigest: String?, outcomes: [URL: ItemDestinationOutcome]) {
        self.item = item
        self.sourceDigest = sourceDigest
        self.outcomes = outcomes
    }
}

/// What the engine hands back when a transfer reaches any terminal state.
public struct TransferReport: Sendable {
    public let id: UUID
    public let status: TransferStatus
    public let algorithm: ChecksumAlgorithm
    public let verificationProfile: VerificationProfile
    public let taskID: UUID
    public let operatorSnapshot: OperatorSnapshot?
    public let projectID: UUID?
    public let sourceFingerprint: String?
    public let sourceRoot: URL
    /// In request order; manifest and UI render destinations in this order.
    public let destinations: [URL]
    public let startedAt: Date
    public let finishedAt: Date
    public let items: [ItemResult]
    /// Transfer-level failures that do not belong to one item/destination pair,
    /// such as an evidence write failure or a source plan changing mid-run.
    public let issues: [String]
    /// Every location a manifest was successfully written (destinations that
    /// were reachable, plus the spool directory).
    public let manifestLocations: [URL]

    public init(
        id: UUID,
        status: TransferStatus,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile = .standard,
        taskID: UUID? = nil,
        operatorSnapshot: OperatorSnapshot? = nil,
        projectID: UUID? = nil,
        sourceFingerprint: String? = nil,
        sourceRoot: URL,
        destinations: [URL],
        startedAt: Date,
        finishedAt: Date,
        items: [ItemResult],
        manifestLocations: [URL],
        issues: [String] = []
    ) {
        self.id = id
        self.status = status
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.taskID = taskID ?? id
        self.operatorSnapshot = operatorSnapshot
        self.projectID = projectID
        self.sourceFingerprint = sourceFingerprint
        self.sourceRoot = sourceRoot
        self.destinations = destinations
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.items = items
        self.manifestLocations = manifestLocations
        self.issues = issues
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.item.size } }

    /// Matches `TransferRequest.shortID` — the slug used in generated file names.
    public var shortID: String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// Counts across every item × destination pair.
    public var verifiedCount: Int { count { $0.isVerified } }
    public var failedCount: Int {
        count { if case .failed = $0 { return true } else { return false } }
    }
    public var skippedCount: Int {
        count { if case .skipped = $0 { return true } else { return false } }
    }
    public var pendingVerificationCount: Int {
        count { if case .transferredPendingVerification = $0 { return true } else { return false } }
    }

    private func count(_ matches: (ItemDestinationOutcome) -> Bool) -> Int {
        items.reduce(0) { total, item in
            total + item.outcomes.values.filter(matches).count
        }
    }
}
