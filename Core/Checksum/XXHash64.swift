/// Streaming XXH64, vendored from the algorithm specification
/// (https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md).
///
/// Not cryptographic, and does not need to be: the threat model is bit rot and
/// truncated writes, not a forger. Correctness is pinned by the reference
/// vectors in `ChecksumTests` and by chunk-boundary invariance — the property
/// the copy loop actually depends on.
public struct XXHash64: StreamingHasher {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    /// Pending input smaller than one 32-byte stripe.
    private var tail: [UInt8]
    private var totalLength: UInt64

    public init(seed: UInt64 = 0) {
        self.seed = seed
        v1 = seed &+ Self.prime1 &+ Self.prime2
        v2 = seed &+ Self.prime2
        v3 = seed
        v4 = seed &- Self.prime1
        tail = []
        tail.reserveCapacity(32)
        totalLength = 0
    }

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard !buffer.isEmpty else { return }
        totalLength &+= UInt64(buffer.count)

        var offset = 0
        if !tail.isEmpty {
            let take = Swift.min(32 - tail.count, buffer.count)
            tail.append(contentsOf: buffer[0..<take])
            offset = take
            if tail.count == 32 {
                let stripe = tail
                stripe.withUnsafeBytes { consumeStripes($0) }
                tail.removeAll(keepingCapacity: true)
            }
        }

        let wholeStripeBytes = ((buffer.count - offset) / 32) * 32
        if wholeStripeBytes > 0 {
            consumeStripes(UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + wholeStripeBytes)]))
            offset += wholeStripeBytes
        }

        if offset < buffer.count {
            tail.append(contentsOf: buffer[offset...])
        }
    }

    public func hexDigest() -> String {
        Self.hexString(finalized())
    }

    /// The raw 64-bit digest of everything fed so far.
    public func finalized() -> UInt64 {
        var hash: UInt64
        if totalLength >= 32 {
            hash = rotl(v1, 1) &+ rotl(v2, 7) &+ rotl(v3, 12) &+ rotl(v4, 18)
            hash = mergeRound(hash, v1)
            hash = mergeRound(hash, v2)
            hash = mergeRound(hash, v3)
            hash = mergeRound(hash, v4)
        } else {
            hash = seed &+ Self.prime5
        }
        hash &+= totalLength

        tail.withUnsafeBytes { buffer in
            var offset = 0
            while offset + 8 <= buffer.count {
                let lane = UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                hash ^= Self.round(0, lane)
                hash = rotl(hash, 27) &* Self.prime1 &+ Self.prime4
                offset += 8
            }
            if offset + 4 <= buffer.count {
                let lane = UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                hash ^= UInt64(lane) &* Self.prime1
                hash = rotl(hash, 23) &* Self.prime2 &+ Self.prime3
                offset += 4
            }
            while offset < buffer.count {
                hash ^= UInt64(buffer[offset]) &* Self.prime5
                hash = rotl(hash, 11) &* Self.prime1
                offset += 1
            }
        }

        hash ^= hash >> 33
        hash &*= Self.prime2
        hash ^= hash >> 29
        hash &*= Self.prime3
        hash ^= hash >> 32
        return hash
    }

    /// Renders the digest as 16 lowercase hex characters, big-endian.
    static func hexString(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    // MARK: - Stripe processing

    /// `buffer.count` must be a positive multiple of 32.
    private mutating func consumeStripes(_ buffer: UnsafeRawBufferPointer) {
        var a = v1, b = v2, c = v3, d = v4
        var offset = 0
        while offset < buffer.count {
            a = Self.round(a, UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self)))
            b = Self.round(b, UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 8, as: UInt64.self)))
            c = Self.round(c, UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 16, as: UInt64.self)))
            d = Self.round(d, UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset + 24, as: UInt64.self)))
            offset += 32
        }
        v1 = a
        v2 = b
        v3 = c
        v4 = d
    }

    private static func round(_ acc: UInt64, _ lane: UInt64) -> UInt64 {
        rotl(acc &+ lane &* prime2, 31) &* prime1
    }

    private func mergeRound(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        (hash ^ Self.round(0, value)) &* Self.prime1 &+ Self.prime4
    }
}

private func rotl(_ value: UInt64, _ amount: UInt64) -> UInt64 {
    (value << amount) | (value >> (64 - amount))
}
