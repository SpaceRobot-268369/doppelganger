/// Why an item failed at a destination (or everywhere). These are ordinary
/// runtime states, not exceptional ones — each has a defined manifest outcome.
public enum ItemFailureReason: Sendable, Hashable {
    case sourceUnreadable(detail: String)
    case sourceUnmounted
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
        case .checksumMismatch(let expected, let actual): "expected \(expected), read back \(actual)"
        default: nil
        }
    }
}

/// Why an item never got its copy attempted or verified at a destination.
public enum ItemSkipReason: String, Sendable, Hashable {
    case cancelled = "cancelled"
    /// The destination failed on an earlier item and was marked dead.
    case destinationUnavailable = "destination-unavailable"
    /// The source became unreadable before this item was reached.
    case sourceUnavailable = "source-unavailable"
}

/// Per item, per destination: `verified`, `failed`, or `skipped` — with a
/// reason. There is no fourth state and no implicit success.
public enum ItemDestinationOutcome: Sendable, Hashable {
    case verified
    case failed(ItemFailureReason)
    case skipped(ItemSkipReason)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// The transfer's overall result. `verified` requires every item to have
/// verified at every destination.
public enum TransferStatus: String, Sendable, Codable {
    case verified
    case failed
    case cancelled
}
