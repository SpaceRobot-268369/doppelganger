import Foundation
import Testing
@testable import Doppelganger

/// An ASC MHL generation that records a failure stores the newly computed
/// (bad) hash with action="failed", and any other format hashed in the same
/// run comes from the same damaged bytes. Verify Existing Media must refuse
/// such a generation as a reference, not compare the damage against itself.
///
/// Synthetic fixtures in a temp directory only (AGENTS.md Principle 3).
struct MHLReferenceActionTests {
    // MARK: - Helpers

    /// One hash-format element inside an ascmhl `<hash>` record.
    private struct HashElement {
        let tag: String
        let action: String
        let value: String
    }

    /// The associated values of `MHLReadError.untrustedHashRecord`.
    private struct UntrustedRecord: Equatable {
        let path: String
        let action: String
        let recordCount: Int
    }

    private static let hashDate = "2026-10-01T12:00:00+00:00"

    private static func digest(_ algorithm: ChecksumAlgorithm, _ bytes: [UInt8]) -> String {
        var hasher = algorithm.makeHasher()
        hasher.update(bytes, count: bytes.count)
        return hasher.hexDigest()
    }

    /// A minimal ascmhl-style v2 generation: one `<hash>` per record, each
    /// hash format written as `<tag action="…" hashdate="…">value</tag>`.
    private static func ascmhl(_ records: [(path: String, size: Int, hashes: [HashElement])]) -> Data {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">"#,
            "  <creatorinfo>",
            "    <creationdate>\(hashDate)</creationdate>",
            "    <hostname>dit-cart</hostname>",
            #"    <tool version="1.0.0">ascmhl.py</tool>"#,
            "  </creatorinfo>",
            "  <processinfo>",
            "    <process>in-place</process>",
            "  </processinfo>",
            "  <hashes>",
        ]
        for record in records {
            lines.append("    <hash>")
            lines.append("      <path size=\"\(record.size)\">\(record.path)</path>")
            for hash in record.hashes {
                lines.append(
                    "      <\(hash.tag) action=\"\(hash.action)\" hashdate=\"\(hashDate)\">\(hash.value)</\(hash.tag)>"
                )
            }
            lines.append("    </hash>")
        }
        lines += ["  </hashes>", "</hashlist>", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func writeReference(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func verify(reference: URL, media: URL, spool: URL) async throws -> TransferReport {
        try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: reference,
            mediaRoot: media,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: spool
        )
    }

    private static func untrustedRecord(_ error: MHLReadError?) -> UntrustedRecord? {
        guard case .untrustedHashRecord(let path, let action, let recordCount)? = error else { return nil }
        return UntrustedRecord(path: path, action: action, recordCount: recordCount)
    }

    // MARK: - Verify Existing Media refuses a failed generation

    /// Port of Repro_G09_mhl.repro_failedActionHashIsNotTrustedAsReference,
    /// tightened: the reference must be refused before any report exists.
    @Test func failedActionRecordIsRefusedAsReference() async throws {
        let fixtures = try FixtureBuilder()
        let good = FixtureBuilder.FileSpec("A001/A001C001.mov", size: 30_000, seed: 41)
        let corrupt = FixtureBuilder.FileSpec("A001/A001C002.mov", size: 50_000, seed: 42)
        let media = try fixtures.makeCard(named: "Backup", files: [good, corrupt])
        let mediaBefore = try fixtures.digestSnapshot(of: media)
        // The bytes on disk for A001C002 are the corrupted ones a later ascmhl
        // run flagged; it recorded their own hash with action="failed".
        let referenceDirectory = try fixtures.makeDestination(named: "reference")
        let reference = try Self.writeReference(
            Self.ascmhl([
                (path: good.path, size: good.size, hashes: [
                    HashElement(tag: "xxh64", action: "verified", value: Self.digest(.xxh64, good.bytes)),
                ]),
                (path: corrupt.path, size: corrupt.size, hashes: [
                    HashElement(tag: "xxh64", action: "failed", value: Self.digest(.xxh64, corrupt.bytes)),
                ]),
            ]),
            named: "0002_Backup_2026-10-01_120000Z.mhl",
            in: referenceDirectory
        )
        let spool = fixtures.root.appendingPathComponent("verify-spool")

        let error = await #expect(throws: MHLReadError.self) {
            _ = try await Self.verify(reference: reference, media: media, spool: spool)
        }

        #expect(Self.untrustedRecord(error) == UntrustedRecord(path: corrupt.path, action: "failed", recordCount: 1))
        let description = try #require(error?.errorDescription)
        #expect(description.contains(corrupt.path), "\(description)")
        // Refused before any spool write: no report or manifest claims anything.
        #expect(!FileManager.default.fileExists(atPath: spool.path))
        // Read-only: the media folder is untouched.
        #expect(try fixtures.digestSnapshot(of: media) == mediaBefore)
    }

    /// A per-algorithm filter would fall back to the md5 "new" hash, which was
    /// taken from the same damaged bytes, and go green. The whole record is
    /// tainted by the failed xxh64.
    @Test func failedHashTaintsEveryFormatInItsRecord() async throws {
        let fixtures = try FixtureBuilder()
        let clip = FixtureBuilder.FileSpec("A001/A001C001.mov", size: 40_000, seed: 43)
        let media = try fixtures.makeCard(named: "Backup", files: [clip])
        let referenceDirectory = try fixtures.makeDestination(named: "reference")
        // Both values match the bytes on disk.
        let reference = try Self.writeReference(
            Self.ascmhl([
                (path: clip.path, size: clip.size, hashes: [
                    HashElement(tag: "md5", action: "new", value: Self.digest(.md5, clip.bytes)),
                    HashElement(tag: "xxh64", action: "failed", value: Self.digest(.xxh64, clip.bytes)),
                ]),
            ]),
            named: "0002_Backup_2026-10-01_120000Z.mhl",
            in: referenceDirectory
        )
        let spool = fixtures.root.appendingPathComponent("verify-spool")

        let error = await #expect(throws: MHLReadError.self) {
            _ = try await Self.verify(reference: reference, media: media, spool: spool)
        }

        #expect(Self.untrustedRecord(error) == UntrustedRecord(path: clip.path, action: "failed", recordCount: 1))
        #expect(!FileManager.default.fileExists(atPath: spool.path))
    }

    @Test func unsupportedFormatFailuresAndUnrecognizedActionsAreRefused() throws {
        let fixtures = try FixtureBuilder()
        let referenceDirectory = try fixtures.makeDestination(named: "reference")
        let first = "A001/A001C001.mov"
        let second = "A001/A001C002.mov"
        let third = "A001/A001C003.mov"

        // (a) A failure on a format the reader cannot use is still seen.
        let unsupportedFailure = try Self.writeReference(
            Self.ascmhl([
                (path: first, size: 10, hashes: [
                    HashElement(tag: "xxh64", action: "verified", value: "0123456789abcdef"),
                    HashElement(tag: "xxh128", action: "failed", value: "00112233445566778899aabbccddeeff"),
                ]),
            ]),
            named: "a.mhl",
            in: referenceDirectory
        )
        let unsupportedError = #expect(throws: MHLReadError.self) {
            _ = try VerificationReference.load(from: unsupportedFailure)
        }
        #expect(
            Self.untrustedRecord(unsupportedError)
                == UntrustedRecord(path: first, action: "failed", recordCount: 1)
        )

        // (b) An unrecognized action fails closed, trimmed and lowercased.
        let unrecognized = try Self.writeReference(
            Self.ascmhl([
                (path: first, size: 10, hashes: [
                    HashElement(tag: "xxh64", action: " Mismatch ", value: "0123456789abcdef"),
                ]),
            ]),
            named: "b.mhl",
            in: referenceDirectory
        )
        let unrecognizedError = #expect(throws: MHLReadError.self) {
            _ = try VerificationReference.load(from: unrecognized)
        }
        #expect(
            Self.untrustedRecord(unrecognizedError)
                == UntrustedRecord(path: first, action: "mismatch", recordCount: 1)
        )

        // (c) Several failed records: the first is named, all are counted.
        let twoFailed = try Self.writeReference(
            Self.ascmhl([
                (path: first, size: 10, hashes: [
                    HashElement(tag: "xxh64", action: "verified", value: "0123456789abcdef"),
                ]),
                (path: second, size: 20, hashes: [
                    HashElement(tag: "xxh64", action: "failed", value: "1111111111111111"),
                ]),
                (path: third, size: 30, hashes: [
                    HashElement(tag: "xxh64", action: "failed", value: "2222222222222222"),
                ]),
            ]),
            named: "c.mhl",
            in: referenceDirectory
        )
        let twoFailedError = #expect(throws: MHLReadError.self) {
            _ = try VerificationReference.load(from: twoFailed)
        }
        #expect(
            Self.untrustedRecord(twoFailedError)
                == UntrustedRecord(path: second, action: "failed", recordCount: 2)
        )
        let description = try #require(twoFailedError?.errorDescription)
        #expect(description.contains(second), "\(description)")
    }

    // MARK: - Over-rejection guard and the suggested remedy

    @Test func trustedActionsStillVerifyAndOriginalGenerationCatchesTheDamage() async throws {
        let fixtures = try FixtureBuilder()
        let intact = FixtureBuilder.FileSpec("A001/A001C001.mov", size: 30_000, seed: 44)
        let damaged = FixtureBuilder.FileSpec("A001/A001C002.mov", size: 50_000, seed: 45)
        let media = try fixtures.makeCard(named: "Backup", files: [intact, damaged])
        let referenceDirectory = try fixtures.makeDestination(named: "reference")

        let original = try Self.writeReference(
            Self.ascmhl([
                (path: intact.path, size: intact.size, hashes: [
                    HashElement(tag: "xxh64", action: "original", value: Self.digest(.xxh64, intact.bytes)),
                ]),
                (path: damaged.path, size: damaged.size, hashes: [
                    HashElement(tag: "xxh64", action: "original", value: Self.digest(.xxh64, damaged.bytes)),
                ]),
            ]),
            named: "0001_Backup_2026-10-01_110000Z.mhl",
            in: referenceDirectory
        )
        let healthy = try Self.writeReference(
            Self.ascmhl([
                (path: intact.path, size: intact.size, hashes: [
                    HashElement(tag: "xxh64", action: "verified", value: Self.digest(.xxh64, intact.bytes)),
                ]),
                (path: damaged.path, size: damaged.size, hashes: [
                    HashElement(tag: "xxh64", action: "Verified", value: Self.digest(.xxh64, damaged.bytes)),
                    HashElement(tag: "md5", action: "new", value: Self.digest(.md5, damaged.bytes)),
                ]),
            ]),
            named: "0002_Backup_2026-10-01_120000Z.mhl",
            in: referenceDirectory
        )

        // 1. Trusted actions (any case) still verify the intact folder.
        let healthyRun = try await Self.verify(
            reference: healthy,
            media: media,
            spool: fixtures.root.appendingPathComponent("healthy-spool")
        )
        #expect(healthyRun.status == .verified)
        #expect(healthyRun.verifiedCount == 2)
        #expect(healthyRun.issues.isEmpty, "\(healthyRun.issues)")

        // 2. Damage one clip on disk (synthetic fixture only).
        let damagedURL = media.appendingPathComponent(damaged.path)
        var bytes = try Data(contentsOf: damagedURL)
        bytes[0] ^= 0xFF
        try bytes.write(to: damagedURL, options: .atomic)

        // 3. The generation that recorded the original hashes catches it.
        let remedy = try await Self.verify(
            reference: original,
            media: media,
            spool: fixtures.root.appendingPathComponent("remedy-spool")
        )
        #expect(remedy.status == .failed)
        #expect(remedy.outcome(intact.path, at: media) == .verified)
        #expect(
            remedy.outcome(damaged.path, at: media)
                == .failed(.checksumMismatch(
                    expected: Self.digest(.xxh64, damaged.bytes),
                    actual: Self.digest(.xxh64, [UInt8](bytes))
                ))
        )
    }

    // MARK: - Reader

    @Test func readerKeepsEveryHashActionOfARecord() throws {
        let document = try MHLReader.read(Self.ascmhl([
            (path: "A001/A001C001.mov", size: 10, hashes: [
                HashElement(tag: "xxh128", action: "failed", value: "00112233445566778899aabbccddeeff"),
                HashElement(tag: "xxh64", action: " New ", value: "0123456789abcdef"),
            ]),
            (path: "A001/A001C002.mov", size: 20, hashes: [
                HashElement(tag: "xxh64", action: "original", value: "fedcba9876543210"),
            ]),
        ]))

        #expect(document.entries.map(\.relativePath) == ["A001/A001C001.mov", "A001/A001C002.mov"])
        #expect(document.entries.map(\.hashActions) == [["failed", "new"], ["original"]])
        #expect(document.entries.map(\.untrustedHashAction) == ["failed", nil])
        // The unsupported format is still not a digest.
        let first = try #require(document.entries.first)
        #expect(first.digests == [.xxh64: "0123456789abcdef"])

        // "failed" wins over an unrecognized action; trusted actions pass.
        func entry(_ actions: [String]) -> MHLDocument.Entry {
            MHLDocument.Entry(relativePath: "x.mov", size: 1, digests: [.xxh64: "00"], hashActions: actions)
        }
        #expect(entry(["bogus", "failed"]).untrustedHashAction == "failed")
        #expect(entry(["verified", "bogus"]).untrustedHashAction == "bogus")
        #expect(entry(["original", "verified", "new"]).untrustedHashAction == nil)
        #expect(entry([]).untrustedHashAction == nil)

        // doppelganger's own generations stay trusted.
        let xml = try #require(
            MHLWriter.xml(for: ReportFixtures.verifiedReport(), destination: ReportFixtures.destinationA)
        )
        let own = try MHLReader.read(Data(xml.utf8))
        #expect(!own.entries.isEmpty)
        #expect(own.entries.allSatisfy { !$0.hashActions.isEmpty })
        #expect(own.entries.allSatisfy { $0.untrustedHashAction == nil })

        // MHL v1 carries no actions and stays trusted.
        let v1 = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<hashlist version="1.1">"#,
            "  <creatorinfo>",
            "    <name>DIT</name>",
            "    <hostname>dit-cart</hostname>",
            "    <tool>OffloadTool 1.0</tool>",
            "    <startdate>2026-10-01T12:00:00Z</startdate>",
            "    <finishdate>2026-10-01T12:01:00Z</finishdate>",
            "  </creatorinfo>",
            "  <hash>",
            "    <file>A001/A001C001.mov</file>",
            "    <size>10</size>",
            "    <lastmodificationdate>2026-10-01T12:00:00Z</lastmodificationdate>",
            "    <xxhash64be>0123456789abcdef</xxhash64be>",
            "    <hashdate>2026-10-01T12:00:30Z</hashdate>",
            "  </hash>",
            "</hashlist>",
            "",
        ].joined(separator: "\n")
        let legacy = try MHLReader.read(Data(v1.utf8))
        #expect(legacy.entries.count == 1)
        let legacyEntry = try #require(legacy.entries.first)
        #expect(legacyEntry.hashActions.isEmpty)
        #expect(legacyEntry.untrustedHashAction == nil)
        #expect(legacyEntry.digests == [.xxh64: "0123456789abcdef"])
    }

    // MARK: - Localization

    @Test func untrustedReferenceMessagesShipInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(
            bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "zh-Hans"
            )
        )
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])

        let singleKey = MHLReadError.untrustedHashRecordKey
        let pluralKey = MHLReadError.untrustedHashRecordsKey
        let single = try #require(catalog[singleKey])
        let plural = try #require(catalog[pluralKey])

        #expect(single != singleKey)
        #expect(single.contains("%1$@"))
        #expect(single.contains("%2$@"))
        #expect(plural != pluralKey)
        #expect(plural.contains("%1$@"))
        #expect(plural.contains("%2$@"))
        #expect(plural.contains("%3$lld"))

        // The positional specifiers render with the arguments errorDescription passes.
        let renderedSingle = String(format: single, locale: nil, "A001/A001C002.mov", "failed")
        #expect(renderedSingle.contains("A001/A001C002.mov"))
        #expect(renderedSingle.contains("failed"))
        let renderedPlural = String(format: plural, locale: nil, "A001/A001C002.mov", "failed", Int64(3))
        #expect(renderedPlural.contains("A001/A001C002.mov"))
        #expect(renderedPlural.contains("failed"))
        #expect(renderedPlural.contains("3"))
    }
}
