/// The hash algorithm used for a transfer. Chosen per transfer and recorded in
/// the manifest — a manifest whose algorithm is unknown is not verifiable later.
public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    /// Default. Fast enough to keep hashing off the copy's critical path.
    /// Digest renders as 16 lowercase hex chars, big-endian (`xxh64be` convention).
    case xxh64

    // An `md5` case is planned for MHL/facility compatibility (feature register
    // P1); it is intentionally absent from the MVP.

    public func makeHasher() -> any StreamingHasher {
        switch self {
        case .xxh64: XXHash64()
        }
    }
}
