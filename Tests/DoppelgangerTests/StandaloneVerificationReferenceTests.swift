import Foundation
import Testing
@testable import Doppelganger

/// Standalone verification never narrows the reference silently. Every file a
/// reference names is expected in the folder: a JSON manifest item without a
/// digest fails (missing-file, or no-reference-digest when present), and an
/// MHL with a `<hash>` record the reader cannot use is refused outright. In
/// neither case may the result be Verified.
///
/// Fixtures only (AGENTS.md Principle 3): every folder lives in a
/// `FixtureBuilder` scratch directory.
struct StandaloneVerificationReferenceTests {
    // MARK: - JSON manifest references

    @Test func digestlessItemMissingFromFolderFailsAsMissingFile() async throws {
        let fixtures = try FixtureBuilder()
        let missingPath = EngineHarness.standardFiles[1].path
        let setup = try await Self.referenceWithoutDigest(for: [missingPath], fixtures: fixtures)
        try FileManager.default.removeItem(at: setup.destination.appendingPathComponent(missingPath))

        let verification = try await Self.runVerification(
            setup.reference,
            setup.destination,
            spool: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .failed)
        #expect(
            verification.outcome(missingPath, at: setup.destination)
                == ItemDestinationOutcome.failed(.missingFile)
        )
        for spec in EngineHarness.standardFiles where spec.path != missingPath {
            #expect(
                verification.outcome(spec.path, at: setup.destination)
                    == ItemDestinationOutcome.verified
            )
        }
        #expect(verification.verifiedCount == 2)
        #expect(verification.failedCount == 1)
        #expect(verification.issues.isEmpty)

        let spoolLocation = try #require(verification.manifestLocations.first)
        let evidence = try EngineHarness.decodeManifest(at: spoolLocation, shortID: verification.shortID)
        #expect(evidence.status == "failed")
        let item = try #require(evidence.items.first { $0.relativePath == missingPath })
        #expect(item.digest == nil)
        #expect(item.results.map(\.reason) == ["missing-file"])
    }

    @Test func digestlessItemPresentInFolderFailsWithNoReferenceDigest() async throws {
        let fixtures = try FixtureBuilder()
        let spec = EngineHarness.standardFiles[1]
        let setup = try await Self.referenceWithoutDigest(for: [spec.path], fixtures: fixtures)
        let target = setup.destination.appendingPathComponent(spec.path)
        // Same bytes, same size: presence plus size alone must never pass.
        try #require(try fixtures.bytes(at: target) == spec.bytes)

        let verification = try await Self.runVerification(
            setup.reference,
            setup.destination,
            spool: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .failed)
        let outcome = verification.outcome(spec.path, at: setup.destination)
        #expect(outcome == ItemDestinationOutcome.failed(.noReferenceDigest))
        #expect(outcome != ItemDestinationOutcome.verified)
        for other in EngineHarness.standardFiles where other.path != spec.path {
            #expect(
                verification.outcome(other.path, at: setup.destination)
                    == ItemDestinationOutcome.verified
            )
        }
        #expect(verification.verifiedCount == 2)
        #expect(verification.failedCount == 1)
        #expect(verification.issues.isEmpty)

        let spoolLocation = try #require(verification.manifestLocations.first)
        let evidence = try EngineHarness.decodeManifest(at: spoolLocation, shortID: verification.shortID)
        #expect(evidence.status == "failed")
        let item = try #require(evidence.items.first { $0.relativePath == spec.path })
        #expect(item.digest == nil)
        #expect(item.results.map(\.reason) == ["no-reference-digest"])

        // Verification is read-only: the media is left exactly as it was.
        #expect(try fixtures.bytes(at: target) == spec.bytes)
    }

    @Test func pausedAttemptManifestReportsUnreachedFilesMissing() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        fileSystem.delayWrites(microseconds: 500)

        let paused = try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("pause-spool"),
            chunkSize: 4 * 1024,
            pauseWhen: { event in
                if case .progress(let progress) = event {
                    return progress.copiedBytes > 32 * 1024
                }
                return false
            }
        )
        try #require(paused.report.status == .paused)

        let pausedManifest = try EngineHarness.decodeManifest(
            at: destination,
            shortID: paused.report.shortID
        )
        let unreached = pausedManifest.items.filter { $0.digest == nil }.map(\.relativePath)
        try #require(!unreached.isEmpty)
        for path in unreached {
            try #require(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(path).path
            ))
        }
        let reference = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: paused.report.shortID)
        )

        let verification = try await Self.runVerification(
            reference,
            destination,
            spool: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .failed)
        for path in unreached {
            #expect(
                verification.outcome(path, at: destination)
                    == ItemDestinationOutcome.failed(.missingFile)
            )
        }
        #expect(verification.failedCount == unreached.count)
        #expect(verification.verifiedCount == pausedManifest.items.count - unreached.count)
        #expect(verification.issues.isEmpty)
    }

    @Test func referenceWithNoDigestsAtAllIsStillRefused() async throws {
        let fixtures = try FixtureBuilder()
        let setup = try await Self.referenceWithoutDigest(
            for: Set(EngineHarness.standardFiles.map(\.path)),
            fixtures: fixtures
        )
        try #require(setup.manifest.items.allSatisfy { $0.digest == nil })
        let spool = fixtures.root.appendingPathComponent("verify-spool")

        do {
            _ = try await Self.runVerification(setup.reference, setup.destination, spool: spool)
            Issue.record("A reference holding no digest at all must be refused")
        } catch MHLReadError.noHashes {
            // Expected: the pre-existing refusal is preserved.
        } catch {
            Issue.record("Expected MHLReadError.noHashes, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: spool.path))
    }

    // MARK: - ASC MHL references

    @Test func mhlRecordWithOnlyUnsupportedDigestIsRefused() async throws {
        let fixtures = try FixtureBuilder()
        let present = FixtureBuilder.FileSpec("Clips/A001.mov", size: 70_000, seed: 11)
        let media = try fixtures.makeCard(named: "media", files: [present])
        let reference = fixtures.root.appendingPathComponent("reference.mhl")
        try Self.unsupportedDigestHashList(present: present).write(to: reference, options: .atomic)
        let spool = fixtures.root.appendingPathComponent("verify-spool")

        do {
            _ = try await Self.runVerification(reference, media, spool: spool)
            Issue.record("Clips/A002.mov is listed with only an unsupported digest; the MHL must be refused")
        } catch MHLReadError.unverifiableHashRecords {
            // Expected: the record is not silently dropped.
        } catch {
            Issue.record("Expected MHLReadError.unverifiableHashRecords, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: spool.path))
    }

    @Test func mhlRecordWithoutSizeIsRefused() async throws {
        let fixtures = try FixtureBuilder()
        let present = FixtureBuilder.FileSpec("Clips/A001.mov", size: 70_000, seed: 11)
        let absent = FixtureBuilder.FileSpec("Clips/A002.mov", size: 40_000, seed: 12)
        let media = try fixtures.makeCard(named: "media", files: [present])
        let reference = fixtures.root.appendingPathComponent("reference.mhl")
        try Self.hashList([
            Self.hashRecord(path: present.path, size: present.size, element: "xxh3", digest: Self.xxh3Digest(of: present)),
            Self.hashRecord(path: absent.path, size: nil, element: "xxh3", digest: Self.xxh3Digest(of: absent)),
        ]).write(to: reference, options: .atomic)
        let spool = fixtures.root.appendingPathComponent("verify-spool")

        do {
            _ = try await Self.runVerification(reference, media, spool: spool)
            Issue.record("Clips/A002.mov is listed without a size; the MHL must be refused")
        } catch MHLReadError.unverifiableHashRecords {
            // Expected.
        } catch {
            Issue.record("Expected MHLReadError.unverifiableHashRecords, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: spool.path))
    }

    @Test func mhlWithEveryRecordUsableStillVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let first = FixtureBuilder.FileSpec("Clips/A001.mov", size: 70_000, seed: 11)
        let second = FixtureBuilder.FileSpec("Clips/A002.mov", size: 40_000, seed: 12)
        let media = try fixtures.makeCard(named: "media", files: [first, second])
        // Stored outside the media folder, so it is never counted as added.
        let reference = fixtures.root.appendingPathComponent("reference.mhl")
        try Self.hashList([
            Self.hashRecord(path: first.path, size: first.size, element: "xxh3", digest: Self.xxh3Digest(of: first)),
            Self.hashRecord(path: second.path, size: second.size, element: "xxh3", digest: Self.xxh3Digest(of: second)),
        ]).write(to: reference, options: .atomic)

        let verification = try await Self.runVerification(
            reference,
            media,
            spool: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .verified)
        #expect(verification.verifiedCount == 2)
        #expect(verification.failedCount == 0)
        #expect(verification.issues.isEmpty)
        #expect(verification.outcome(first.path, at: media) == ItemDestinationOutcome.verified)
        #expect(verification.outcome(second.path, at: media) == ItemDestinationOutcome.verified)
    }

    @Test func readerKeepsUsableEntriesAndCountsUnusableRecords() throws {
        let present = FixtureBuilder.FileSpec("Clips/A001.mov", size: 70_000, seed: 11)

        let document = try MHLReader.read(Self.unsupportedDigestHashList(present: present))

        #expect(document.entries.map(\.relativePath) == ["Clips/A001.mov"])
        #expect(document.entries.first?.size == Int64(present.size))
        #expect(document.entries.first?.digests[.xxh3] == Self.xxh3Digest(of: present))
        #expect(document.unusableHashRecordCount == 1)

        // A list whose every record is usable counts nothing.
        let clean = try MHLReader.read(Self.hashList([
            Self.hashRecord(path: present.path, size: present.size, element: "xxh3", digest: Self.xxh3Digest(of: present)),
        ]))
        #expect(clean.unusableHashRecordCount == 0)
    }

    @Test func unverifiableMHLRefusalShipsInSimplifiedChinese() throws {
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
        let key = MHLReadError.unverifiableHashRecordsKey

        let translation = try #require(catalog[key])
        #expect(translation != key)
        #expect(MHLReadError.unverifiableHashRecords.errorDescription == L10n.text(key))
    }

    // MARK: - Helpers

    private struct DigestlessReference {
        let destination: URL
        let reference: URL
        let manifest: TransferManifest
    }

    private static func runVerification(
        _ reference: URL,
        _ media: URL,
        spool: URL
    ) async throws -> TransferReport {
        try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: reference,
            mediaRoot: media,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: spool
        )
    }

    /// A verified xxh3 copy of the standard card, plus a reference manifest
    /// beside (not inside) the destination in which `paths` carry no digest —
    /// the shape a paused, cancelled, or source-dead attempt writes for items
    /// it never read.
    private static func referenceWithoutDigest(
        for paths: Set<String>,
        fixtures: FixtureBuilder
    ) async throws -> DigestlessReference {
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let copy = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("copy-spool"),
            algorithm: .xxh3
        )
        try #require(copy.report.status == .verified)

        var manifest = try EngineHarness.decodeManifest(at: destination, shortID: copy.report.shortID)
        for path in paths {
            let index = try #require(manifest.items.firstIndex { $0.relativePath == path })
            manifest.items[index].digest = nil
        }
        let reference = fixtures.root.appendingPathComponent("reference.json")
        try ManifestWriter.jsonData(for: manifest).write(to: reference, options: .atomic)
        return DigestlessReference(destination: destination, reference: reference, manifest: manifest)
    }

    private static func xxh3Digest(of spec: FixtureBuilder.FileSpec) -> String {
        var hasher = ChecksumAlgorithm.xxh3.makeHasher()
        let bytes = spec.bytes
        bytes.withUnsafeBytes { raw in
            hasher.update(raw)
        }
        return hasher.hexDigest()
    }

    /// The G02 repro list: `present` with a supported digest and a size, and
    /// Clips/A002.mov (absent from any folder) with only an xxh128 digest.
    private static func unsupportedDigestHashList(present: FixtureBuilder.FileSpec) -> Data {
        hashList([
            hashRecord(path: present.path, size: present.size, element: "xxh3", digest: xxh3Digest(of: present)),
            hashRecord(path: "Clips/A002.mov", size: 4096, element: "xxh128", digest: "0123456789abcdef0123456789abcdef"),
        ])
    }

    private static func hashRecord(path: String, size: Int?, element: String, digest: String) -> [String] {
        let sizeAttribute = size.map { " size=\"\($0)\"" } ?? ""
        return [
            "    <hash>",
            "      <path\(sizeAttribute)>\(path)</path>",
            "      <\(element) action=\"original\" hashdate=\"2026-01-01T00:00:00Z\">\(digest)</\(element)>",
            "    </hash>",
        ]
    }

    private static func hashList(_ records: [[String]]) -> Data {
        let lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">",
            "  <hashes>",
        ] + records.flatMap { $0 } + [
            "  </hashes>",
            "</hashlist>",
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }
}
