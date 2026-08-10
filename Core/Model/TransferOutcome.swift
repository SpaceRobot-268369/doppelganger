/// Why an item failed at a destination (or everywhere). These are ordinary
/// runtime states, not exceptional ones — each has a defined manifest outcome.
public enum ItemFailureReason: Sendable, Hashable {
    case sourceUnreadable(detail: String)
    case sourceUnmounted
    case sourceChanged
    case emptySource
    case zeroByteSource
    case missingFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case destinationUnmounted
    case destinationFull
    case checksumMismatch(expected: String, actual: String)
    case nameCollision
    case writeFailed(detail: String)
    case cancelled

    /// Stable machine-readable slug recorded in the manifest.
    public var slug: String {
        switch self {
        case .sourceUnreadable: "source-unreadable"
        case .sourceUnmounted: "source-unmounted"
        case .sourceChanged: "source-changed"
        case .emptySource: "empty-source"
        case .zeroByteSource: "zero-byte-source"
        case .missingFile: "missing-file"
        case .sizeMismatch: "size-mismatch"
        case .destinationUnmounted: "destination-unmounted"
        case .destinationFull: "destination-full"
        case .checksumMismatch: "checksum-mismatch"
        case .nameCollision: "name-collision"
        case .writeFailed: "write-failed"
        case .cancelled: "cancelled"
        }
    }

    public var detail: String? {
        switch self {
        case .sourceUnreadable(let detail), .writeFailed(let detail): detail
        case .sizeMismatch(let expected, let actual): "expected \(expected) bytes, found \(actual)"
        case .checksumMismatch(let expected, let actual): "expected \(expected), read back \(actual)"
        default: nil
        }
    }
}

/// Why an item never got its copy attempted or verified at a destination.
public enum ItemSkipReason: String, Sendable, Hashable {
    case cancelled = "cancelled"
    /// The operator requested a safe pause before this pair was attempted.
    case paused = "paused"
    /// The destination failed on an earlier item and was marked dead.
    case destinationUnavailable = "destination-unavailable"
    /// The source became unreadable before this item was reached.
    case sourceUnavailable = "source-unavailable"
}

/// Per item, per destination: `verified`, `failed`, or `skipped` — with a
/// reason. There is no fourth state and no implicit success.
public enum ItemDestinationOutcome: Sendable, Hashable {
    case verified
    /// A pre-existing destination file was independently re-hashed and
    /// matched the reviewed source digest, so no bytes were rewritten.
    case verifiedDuplicate
    /// Bytes were copied and basic destination metadata matched, but an
    /// independent destination read-back has not happened yet.
    case transferredPendingVerification
    case failed(ItemFailureReason)
    case skipped(ItemSkipReason)

    public var isVerified: Bool {
        switch self {
        case .verified, .verifiedDuplicate: true
        default: false
        }
    }

    public var isTransferredPendingVerification: Bool {
        if case .transferredPendingVerification = self { return true }
        return false
    }
}

/// The transfer's overall result. `verified` requires every item to have
/// verified at every destination.
public enum TransferStatus: String, Sendable, Codable {
    case paused
    case transferredPendingVerification
    case verified
    case failed
    case cancelled
}
