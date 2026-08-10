/// The hash algorithm used for a transfer. Chosen per transfer and recorded in
/// the manifest — a manifest whose algorithm is unknown is not verifiable later.
public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable {
    /// Product default and fastest supported option.
    case xxh3 = "xxh3"

    /// ASC MHL-compatible big-endian xxHash64 representation.
    case xxh64 = "xxh64be"

    /// Compatibility only, for MHL workflows and facilities that require MD5.
    /// Digest renders as 32 lowercase hex chars. Slower than xxh64.
    case md5

    public func makeHasher() -> any StreamingHasher {
        switch self {
        case .xxh3: XXH3Streaming()
        case .xxh64: XXHash64()
        case .md5: MD5()
        }
    }

    /// User-facing name.
    public var displayName: String {
        switch self {
        case .xxh3: "XXH3-64"
        case .xxh64: "XXH64BE"
        case .md5: "MD5"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Schema-v1 journals and manifests used the shorter legacy spelling.
        if value == "xxh64" {
            self = .xxh64
        } else if let algorithm = Self(rawValue: value) {
            self = algorithm
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported checksum algorithm: \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
