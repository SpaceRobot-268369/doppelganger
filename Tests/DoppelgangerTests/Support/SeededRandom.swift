/// Deterministic pseudo-random bytes for fixtures and checksum tests.
/// SplitMix64 — tiny, seedable, and stable across platforms and releases.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func bytes(count: Int, seed: UInt64) -> [UInt8] {
        var generator = SplitMix64(seed: seed)
        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            var word = generator.next()
            for _ in 0..<8 where result.count < count {
                result.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return result
    }
}
