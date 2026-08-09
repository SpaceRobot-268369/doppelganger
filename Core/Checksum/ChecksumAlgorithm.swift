/// The hash algorithm used for a transfer. Chosen per transfer and recorded in
/// the manifest — a manifest whose algorithm is unknown is not verifiable later.
public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    /// Default. Fast enough to keep hashing off the copy's critical path.
    /// Digest renders as 16 lowercase hex chars, big-endian (`xxh64be` convention).
    case xxh64

    /// Compatibility only, for MHL workflows and facilities that require MD5.
    /// Digest renders as 32 lowercase hex chars. Slower than xxh64.
    case md5

    public func makeHasher() -> any StreamingHasher {
        switch self {
        case .xxh64: XXHash64()
        case .md5: MD5()
        }
    }

    /// User-facing name.
    public var displayName: String {
        switch self {
        case .xxh64: "xxHash64"
        case .md5: "MD5"
        }
    }
}
