import Foundation

public enum VerificationProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case fast
    case standard
    case maximum

    public var id: String { rawValue }

    public var displayName: String {
        let key = switch self {
        case .fast: "Fast"
        case .standard: "Standard"
        case .maximum: "Maximum"
        }
        return NSLocalizedString(key, comment: "Verification profile")
    }

    public var detail: String {
        let key = switch self {
        case .fast: "Copy now; complete destination verification later."
        case .standard: "Copy, then fully read back every destination."
        case .maximum: "Pre-read the source, copy, then fully read back every destination."
        }
        return NSLocalizedString(key, comment: "Verification profile detail")
    }
}

/// Where a transfer's files land inside each destination.
public enum DestinationLayout: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Everything goes into a new folder created inside each destination. The
    /// default, and the only layout that guarantees an empty output.
    case newFolder
    /// Files and folders are written straight into each destination, beside
    /// whatever is already there.
    case directly

    public var id: String { rawValue }

    public var displayName: String {
        let key = switch self {
        case .newFolder: "New folder"
        case .directly: "Directly in destination"
        }
        return NSLocalizedString(key, comment: "Destination layout")
    }

    public var detail: String {
        let key = switch self {
        case .newFolder:
            "A new folder with the transfer name is created inside every destination."
        case .directly:
            "Files are written straight into every destination, beside what is already there. Existing files are never overwritten — a name collision fails that file instead."
        }
        return NSLocalizedString(key, comment: "Destination layout detail")
    }
}

public enum TransferAttemptKind: String, Codable, Sendable {
    case copy
    case resume
    case retry
    case verification
    case cascade
    case contactSheet
}

public enum TaskLifecycle: String, Codable, Sendable {
    case queued
    case scanning
    case copying
    case paused
    case transferredPendingVerification
    case verifying
    case writingEvidence
    case complete
    case failed
    case cancelled
}

public enum TransferVerdict: String, Codable, Sendable {
    case pending
    case paused
    case transferredPendingVerification
    case verified
    case needsAttention
    case failed
    case cancelled
}

public enum OperatorAvatarKind: String, Codable, Sendable {
    case initials
    case image
}

public struct OperatorAvatar: Codable, Hashable, Sendable {
    public var kind: OperatorAvatarKind
    public var colorHex: String
    /// A file name relative to the app-owned Avatars directory. Never an
    /// external path that can disappear or grant broader access.
    public var imageFileName: String?

    public init(
        kind: OperatorAvatarKind = .initials,
        colorHex: String = "4A90E2",
        imageFileName: String? = nil
    ) {
        self.kind = kind
        self.colorHex = colorHex
        self.imageFileName = imageFileName
    }
}

public struct OperatorProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var avatar: OperatorAvatar
    public var createdAt: Date
    public var updatedAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        avatar: OperatorAvatar = OperatorAvatar(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.avatar = avatar
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
    }

    public var isArchived: Bool { archivedAt != nil }

    public var initials: String {
        let components = displayName
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .prefix(2)
        let value = components.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }
}

public struct ProjectRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String
    public var productionCompany: String
    public var shootLocation: String
    public var shootStartDate: Date?
    public var shootEndDate: Date?
    public var createdAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        productionCompany: String = "",
        shootLocation: String = "",
        shootStartDate: Date? = nil,
        shootEndDate: Date? = nil,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.productionCompany = productionCompany
        self.shootLocation = shootLocation
        self.shootStartDate = shootStartDate
        self.shootEndDate = shootEndDate
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }
}

/// A camera on a production, and the reel/tape naming it owns.
///
/// The industry convention is a per-camera letter plus a running tape number —
/// A001, A002 for the A camera, B001 for the B camera. `reelPrefix` holds the
/// letter; the number is suggested from what that camera has already offloaded,
/// and the operator can always override it.
public struct CameraRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var projectID: UUID
    /// The camera's reel letter — "A", "B", "C". Normalized to uppercase.
    public var reelPrefix: String
    /// What the crew calls this camera, e.g. "A Camera" or "Drone".
    public var name: String
    public var make: String
    public var model: String
    public var notes: String
    public var createdAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        reelPrefix: String,
        name: String,
        make: String = "",
        model: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.reelPrefix = CameraRecord.normalizedPrefix(reelPrefix)
        self.name = name
        self.make = make
        self.model = model
        self.notes = notes
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }

    /// The label the catalog stores for this camera. Falls back to the reel
    /// letter so a camera is never nameless in history.
    public var displayName: String {
        name.isEmpty ? "\(reelPrefix) Camera" : name
    }

    public var hardwareDescription: String {
        [make, model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Reel/tape name for a given tape number, e.g. prefix "A" + 1 → "A001".
    public func reelName(number: Int) -> String {
        "\(reelPrefix)\(String(format: "%03d", max(number, 1)))"
    }

    /// A reel letter is one or two uppercase letters; anything else is trimmed
    /// away so the generated tape names stay conventional.
    public static func normalizedPrefix(_ raw: String) -> String {
        let letters = raw.uppercased().filter { $0.isLetter }
        return String(letters.prefix(2))
    }

    /// Reads the tape number out of a reel name like "A001" when the prefix
    /// matches, so the next suggestion can continue the run.
    public func tapeNumber(inReelName reelName: String) -> Int? {
        let value = reelName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.hasPrefix(reelPrefix) else { return nil }
        let digits = value.dropFirst(reelPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

/// Searchable catalog projection for one logical transfer task. Evidence on
/// disk stays authoritative; this row is the durable organization index used
/// by Projects and history views.
public struct TaskHistoryRecord: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var label: String
    public var sourcePath: String
    public var sourceFingerprint: String?
    public var sourceVolumeIdentifier: String?
    public var sourceVolumeName: String?
    public var destinationPaths: [String]
    public var projectID: UUID?
    public var projectName: String?
    /// Mutable catalog-only organization. These values never alter the
    /// immutable transfer manifest or any evidence stored beside the media.
    public var shootingDay: String?
    public var cameraLabel: String?
    public var cardLabel: String?
    public var searchableAttemptText: String
    public var searchableEvidenceText: String
    public var operatorSnapshot: OperatorSnapshot
    public var algorithm: ChecksumAlgorithm
    public var verificationProfile: VerificationProfile
    public var lifecycle: TaskLifecycle
    public var verdict: TransferVerdict
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        label: String,
        sourcePath: String,
        sourceFingerprint: String? = nil,
        sourceVolumeIdentifier: String? = nil,
        sourceVolumeName: String? = nil,
        destinationPaths: [String],
        projectID: UUID?,
        projectName: String?,
        shootingDay: String? = nil,
        cameraLabel: String? = nil,
        cardLabel: String? = nil,
        searchableAttemptText: String = "",
        searchableEvidenceText: String = "",
        operatorSnapshot: OperatorSnapshot,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile,
        lifecycle: TaskLifecycle,
        verdict: TransferVerdict,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.label = label
        self.sourcePath = sourcePath
        self.sourceFingerprint = sourceFingerprint
        self.sourceVolumeIdentifier = sourceVolumeIdentifier
        self.sourceVolumeName = sourceVolumeName
        self.destinationPaths = destinationPaths
        self.projectID = projectID
        self.projectName = projectName
        self.shootingDay = shootingDay
        self.cameraLabel = cameraLabel
        self.cardLabel = cardLabel
        self.searchableAttemptText = searchableAttemptText
        self.searchableEvidenceText = searchableEvidenceText
        self.operatorSnapshot = operatorSnapshot
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.lifecycle = lifecycle
        self.verdict = verdict
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SourceHistoryRelationship: String, Sendable {
    case unchanged
    case changed
    case similar
    case unrelated
}

public extension TaskHistoryRecord {
    func relationship(
        toFingerprint fingerprint: String,
        volumeIdentifier: String?,
        volumeName: String?
    ) -> SourceHistoryRelationship {
        if sourceFingerprint == fingerprint { return .unchanged }
        if let volumeIdentifier,
           let sourceVolumeIdentifier,
           sourceVolumeIdentifier == volumeIdentifier {
            return .changed
        }
        if let volumeName,
           let sourceVolumeName,
           sourceVolumeName.localizedCaseInsensitiveCompare(volumeName) == .orderedSame {
            return .similar
        }
        return .unrelated
    }
}

public struct AttemptHistoryRecord: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var parentAttemptID: UUID?
    public var kind: TransferAttemptKind
    public var operatorSnapshot: OperatorSnapshot
    public var algorithm: ChecksumAlgorithm
    public var verificationProfile: VerificationProfile
    public var lifecycle: TaskLifecycle
    public var verdict: TransferVerdict
    public var startedAt: Date?
    public var finishedAt: Date?
    public var issues: [String]
    public var fileCount: Int

    public init(
        id: UUID,
        taskID: UUID,
        parentAttemptID: UUID?,
        kind: TransferAttemptKind,
        operatorSnapshot: OperatorSnapshot,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile,
        lifecycle: TaskLifecycle,
        verdict: TransferVerdict,
        startedAt: Date?,
        finishedAt: Date?,
        issues: [String],
        fileCount: Int
    ) {
        self.id = id
        self.taskID = taskID
        self.parentAttemptID = parentAttemptID
        self.kind = kind
        self.operatorSnapshot = operatorSnapshot
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.lifecycle = lifecycle
        self.verdict = verdict
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.issues = issues
        self.fileCount = fileCount
    }
}

public struct EvidenceArtifactHistoryRecord: Hashable, Identifiable, Sendable {
    public var id: UUID
    public var attemptID: UUID
    public var kind: String
    public var path: String
    public var required: Bool
    public var status: String
    public var warning: String?

    public init(
        id: UUID,
        attemptID: UUID,
        kind: String,
        path: String,
        required: Bool,
        status: String,
        warning: String? = nil
    ) {
        self.id = id
        self.attemptID = attemptID
        self.kind = kind
        self.path = path
        self.required = required
        self.status = status
        self.warning = warning
    }
}

public enum AuditActorKind: String, Codable, Sendable {
    case operatorProfile
    case system
}

public enum AuditAction: String, Codable, CaseIterable, Sendable {
    case taskCreated
    case taskStarted
    case taskPaused
    case taskResumed
    case taskCancelled
    case retryCreated
    case verificationCreated
    case cascadeCreated
    case contactSheetCreated
    case projectChanged
    case taskOrganizationChanged
    case warningAcknowledged
    case safeEjectRequested
    case attemptCompleted
    case attemptFailed
}

public struct OperatorSnapshot: Codable, Hashable, Sendable {
    public var profileID: UUID
    public var displayName: String

    public init(profileID: UUID, displayName: String) {
        self.profileID = profileID
        self.displayName = displayName
    }

    public init(profile: OperatorProfile) {
        self.init(profileID: profile.id, displayName: profile.displayName)
    }
}

public struct AuditEventRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var taskID: UUID?
    public var attemptID: UUID?
    public var actorKind: AuditActorKind
    public var operatorSnapshot: OperatorSnapshot?
    public var action: AuditAction
    public var occurredAt: Date
    public var detail: String?

    public init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        attemptID: UUID? = nil,
        actorKind: AuditActorKind,
        operatorSnapshot: OperatorSnapshot? = nil,
        action: AuditAction,
        occurredAt: Date = Date(),
        detail: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.actorKind = actorKind
        self.operatorSnapshot = operatorSnapshot
        self.action = action
        self.occurredAt = occurredAt
        self.detail = detail
    }
}
