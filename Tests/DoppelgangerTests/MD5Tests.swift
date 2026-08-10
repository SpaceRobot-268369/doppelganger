import Foundation
import Testing
@testable import Doppelganger

struct MD5Tests {
    private func digest(of bytes: [UInt8], chunkSize: Int? = nil) -> String {
        var hasher = MD5()
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

    // Reference vectors from RFC 1321 §A.5.

    @Test func rfc1321ReferenceVectorsMatch() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
        ]
        for (input, expected) in vectors {
            #expect(digest(of: Array(input.utf8)) == expected, "\(input)")
        }
    }

    @Test func chunkBoundariesDoNotAffectDigest() {
        // Same property the copy loop depends on for xxh64: streamed digests
        // must equal one-shot digests at every chunk size, including sizes that
        // straddle the 64-byte block and the padding boundary.
        let data = SplitMix64.bytes(count: 262_144 + 61, seed: 0x3D5A_11E2)
        let oneShot = digest(of: data)
        for chunkSize in [1, 3, 55, 56, 63, 64, 65, 4096, 65_536] {
            #expect(digest(of: data, chunkSize: chunkSize) == oneShot, "chunk size \(chunkSize)")
        }
    }

    @Test func paddingBoundaryLengthsMatchOneShot() {
        // Message lengths around the 56-byte padding cliff and block edges are
        // where padding bugs live; every length must round-trip identically
        // when streamed byte-by-byte.
        for length in [0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129] {
            let data = SplitMix64.bytes(count: length, seed: UInt64(length) &+ 7)
            #expect(digest(of: data, chunkSize: 1) == digest(of: data), "length \(length)")
        }
    }

    @Test func digestIsAlwaysThirtyTwoLowercaseHexCharacters() {
        for length in [0, 1, 55, 64, 100] {
            let hex = digest(of: SplitMix64.bytes(count: length, seed: UInt64(length)))
            #expect(hex.count == 32)
            #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test func finalizeIsNonDestructive() {
        var hasher = MD5()
        Array("first".utf8).withUnsafeBytes { hasher.update($0) }
        let first = hasher.hexDigest()
        #expect(first == hasher.hexDigest())
        Array("second".utf8).withUnsafeBytes { hasher.update($0) }
        #expect(hasher.hexDigest() != first)
    }

    @Test func engineTransferWithMD5VerifiesAndRecordsMD5Digests() async throws {
        // The whole pipeline honors the per-request algorithm: copy hashes,
        // verify re-reads, and the manifest all speak MD5.
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"), algorithm: .md5)

        #expect(run.report.status == .verified)
        #expect(run.report.algorithm == .md5)
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: run.report.shortID)
        #expect(manifest.algorithm == "md5")
        for spec in EngineHarness.standardFiles {
            let recorded = try #require(run.report.items.first { $0.item.relativePath == spec.path }?.sourceDigest)
            #expect(recorded == digest(of: spec.bytes), "\(spec.path)")
        }
    }

    @Test func algorithmCaseProducesMD5Hasher() {
        var hasher = ChecksumAlgorithm.md5.makeHasher()
        Array("abc".utf8).withUnsafeBytes { hasher.update($0) }
        #expect(hasher.hexDigest() == "900150983cd24fb0d6963f7d28e17f72")
    }
}
