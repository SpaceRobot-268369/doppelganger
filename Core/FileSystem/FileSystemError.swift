/// Typed file-system failures. A dropped card, an unmounted volume, and a full
/// destination are expected runtime states, not programmer errors — Platform
/// maps errno onto these and the engine maps them onto `ItemFailureReason`.
public enum FileSystemError: Error, Sendable, Hashable {
    /// Destination has no room (ENOSPC / EDQUOT).
    case noSpace
    /// The volume or path disappeared out from under us (ENODEV, ENXIO,
    /// EIO on a yanked device, or a vanished parent directory).
    case volumeGone
    /// The file exists but cannot be read (EACCES, EPERM, unreadable sectors).
    case notReadable(detail: String)
    /// Exclusive create found an existing file (EEXIST) — a name collision.
    case alreadyExists
    case other(code: Int32, detail: String)
}
