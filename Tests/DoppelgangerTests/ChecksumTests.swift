import Testing
@testable import Doppelganger

struct ChecksumTests {
    private func digest(of bytes: [UInt8], chunkSize: Int? = nil, seed: UInt64 = 0) -> String {
        var hasher = XXHash64(seed: seed)
        if let chunkSize {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset + chunkSize, bytes.count)
                Array(bytes[offset..<end]).withUnsafeBytes { hasher.update($0) }
                offset = end
            }
        } else {
            bytes.withUnsafeBytes { hasher.update($0) }
        }
        return hasher.hexDigest()
    }

    // Reference vectors: XXH64, seed 0, from the published xxHash test values
    // (xxHash repository / algorithm documentation).

    @Test func emptyInputMatchesReferenceVector() {
        #expect(digest(of: []) == "ef46db3751d8e999")
    }

    @Test func shortInputMatchesReferenceVector() {
        // "abc" — exercises the < 32-byte tail-only path.
        #expect(digest(of: Array("abc".utf8)) == "44bc2cf5ad770999")
    }

    @Test func stripeSizedInputMatchesReferenceVector() {
        // 43 bytes — exercises the >= 32-byte stripe path plus tail.
        let fox = Array("The quick brown fox jumps over the lazy dog".utf8)
        #expect(digest(of: fox) == "0b242d361fda71bc")
    }

    @Test func chunkBoundariesDoNotAffectDigest() {
        // The property the copy loop depends on: a digest streamed in bounded
        // chunks equals the one-shot digest, whatever the chunk size.
        let data = SplitMix64.bytes(count: 1_048_576 + 17, seed: 0xD0BB_E164)
        let oneShot = digest(of: data)
        for chunkSize in [1, 3, 31, 32, 33, 4096, 65_536, 1_048_576] {
            #expect(digest(of: data, chunkSize: chunkSize) == oneShot, "chunk size \(chunkSize)")
        }
    }

    @Test func digestIsAlwaysSixteenLowercaseHexCharacters() {
        // Rendering must left-pad: 0x00ab… would otherwise lose its zeros.
        #expect(XXHash64.hexString(0x0000_00AB_CDEF_0123) == "000000abcdef0123")
        #expect(XXHash64.hexString(0) == "0000000000000000")
        #expect(XXHash64.hexString(.max) == "ffffffffffffffff")
        for length in [0, 1, 4, 31, 32, 33, 100] {
            let hex = digest(of: SplitMix64.bytes(count: length, seed: UInt64(length)))
            #expect(hex.count == 16)
            #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test func seedChangesTheDigest() {
        let data = Array("doppelganger".utf8)
        #expect(digest(of: data, seed: 0) != digest(of: data, seed: 1))
    }

    @Test func finalizeIsNonDestructive() {
        // The engine may render a digest and keep streaming; finalizing twice
        // with no new input must agree.
        var hasher = XXHash64()
        Array("first".utf8).withUnsafeBytes { hasher.update($0) }
        let first = hasher.hexDigest()
        #expect(first == hasher.hexDigest())
        Array("second".utf8).withUnsafeBytes { hasher.update($0) }
        #expect(hasher.hexDigest() != first)
    }
}
