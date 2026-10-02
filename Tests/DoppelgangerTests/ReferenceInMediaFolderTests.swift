import Foundation
import Testing
@testable import Doppelganger

/// verify-evidence-5: the reference chosen for Verify Existing Media is
/// evidence, not media. An MHL v1 sits in the root of the folder it
/// describes; verifying that folder against it must not report the .mhl
/// itself as an added file. Every other unlisted file still is (fail closed).
///
/// Synthetic fixtures in a temp directory only (AGENTS.md Principle 3).
struct ReferenceInMediaFolderTests {
    private static let clips: [FixtureBuilder.FileSpec] = [
        .init("A001/A001C001.mov", size: 40_000, seed: 51),
        .init("A001/A001C002.mov", size: 20_000, seed: 52),
    ]
    private static let referenceName = "CardA_2026-10-01_120100.mhl"

    private static func xxh64(_ bytes: [UInt8]) -> String {
        var hasher = ChecksumAlgorithm.xxh64.makeHasher()
        hasher.update(bytes, count: bytes.count)
        return hasher.hexDigest()
    }

    /// A Hedge/ShotPut-style MHL v1 hash list; `<file>` paths are relative
    /// to the folder the .mhl is written into.
    private static func mhlV1(_ specs: [FixtureBuilder.FileSpec]) -> Data {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<hashlist version="1.1">"#,
            "  <creatorinfo>",
            "    <name>DIT</name>",
            "    <username>dit</username>",
            "    <hostname>dit-cart</hostname>",
            "    <tool>OffloadTool 1.0</tool>",
            "    <startdate>2026-10-01T12:00:00Z</startdate>",
            "    <finishdate>2026-10-01T12:01:00Z</finishdate>",
            "  </creatorinfo>",
        ]
        for spec in specs {
            lines += [
                "  <hash>",
                "    <file>\(spec.path)</file>",
                "    <size>\(spec.size)</size>",
                "    <lastmodificationdate>2026-10-01T12:00:00Z</lastmodificationdate>",
                "    <xxhash64be>\(xxh64(spec.bytes))</xxhash64be>",
                "    <hashdate>2026-10-01T12:00:30Z</hashdate>",
                "  </hash>",
            ]
        }
        lines += ["</hashlist>", ""]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func verify(
        reference: URL,
        media: URL,
        fixtures: FixtureBuilder
    ) async throws -> TransferReport {
        try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: reference,
            mediaRoot: media,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: fixtures.root.appendingPathComponent("verify-spool")
        )
    }

    /// Port of Repro_G09_mhl.repro_mhlV1InsideMediaRootIsNotAnAddedFile,
    /// tightened: no failures, the report lists only the clips, and the
    /// media folder (reference included) is byte-for-byte untouched.
    @Test func mhlV1InsideMediaRootIsNotAnAddedFile() async throws {
        let fixtures = try FixtureBuilder()
        let media = try fixtures.makeCard(named: "CardA", files: Self.clips)
        let reference = media.appendingPathComponent(Self.referenceName)
        try Self.mhlV1(Self.clips).write(to: reference)
        let before = try fixtures.digestSnapshot(of: media)

        let verification = try await Self.verify(reference: reference, media: media, fixtures: fixtures)

        #expect(verification.status == .verified)
        #expect(verification.verifiedCount == Self.clips.count)
        #expect(verification.failedCount == 0)
        #expect(verification.issues.isEmpty, "\(verification.issues)")
        #expect(Set(verification.items.map(\.item.relativePath)) == Set(Self.clips.map(\.path)))
        #expect(try fixtures.digestSnapshot(of: media) == before)
    }

    /// Only the chosen reference is set aside: a byte-identical second .mhl
    /// and an unlisted clip in the same folder are still added files.
    @Test func onlyTheChosenReferenceIsSetAside() async throws {
        let fixtures = try FixtureBuilder()
        let media = try fixtures.makeCard(named: "CardA", files: Self.clips)
        let reference = media.appendingPathComponent(Self.referenceName)
        try Self.mhlV1(Self.clips).write(to: reference)
        let otherMHL = "CardA_2026-09-30_090000.mhl"
        try Self.mhlV1(Self.clips).write(to: media.appendingPathComponent(otherMHL))
        let stray = FixtureBuilder.FileSpec("A001/A001C003.mov", size: 10_000, seed: 53)
        try Data(stray.bytes).write(to: media.appendingPathComponent(stray.path))

        let verification = try await Self.verify(reference: reference, media: media, fixtures: fixtures)

        #expect(verification.status == .failed)
        #expect(verification.verifiedCount == Self.clips.count)
        #expect(verification.issues.count == 1)
        let finding = try #require(verification.issues.first)
        #expect(finding.contains(otherMHL))
        #expect(finding.contains(stray.path))
        #expect(!finding.contains(Self.referenceName))
    }

    /// The match is by location, not by name or content: with the reference
    /// kept outside the media folder, an identical same-named .mhl inside it
    /// is still an added file.
    @Test func sameNamedCopyIsAddedWhenTheReferenceLivesElsewhere() async throws {
        let fixtures = try FixtureBuilder()
        let media = try fixtures.makeCard(named: "CardA", files: Self.clips)
        let elsewhere = try fixtures.makeDestination(named: "reference")
        let reference = elsewhere.appendingPathComponent(Self.referenceName)
        try Self.mhlV1(Self.clips).write(to: reference)
        try Self.mhlV1(Self.clips).write(to: media.appendingPathComponent(Self.referenceName))

        let verification = try await Self.verify(reference: reference, media: media, fixtures: fixtures)

        #expect(verification.status == .failed)
        #expect(verification.verifiedCount == Self.clips.count)
        #expect(verification.issues.count == 1)
        #expect(verification.issues.first?.contains(Self.referenceName) == true)
    }

    /// The reference is matched by canonical path, as enumeration spells it:
    /// a media folder chosen through a symlink and a reference URL carrying
    /// `..` components still resolve to the same file.
    @Test func referenceIsMatchedByCanonicalPath() async throws {
        let fixtures = try FixtureBuilder()
        let media = try fixtures.makeCard(named: "CardA", files: Self.clips)
        try Self.mhlV1(Self.clips).write(to: media.appendingPathComponent(Self.referenceName))
        let link = fixtures.root.appendingPathComponent("CardA-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: media)
        let reference = media.appendingPathComponent("A001/../\(Self.referenceName)")

        let verification = try await Self.verify(reference: reference, media: link, fixtures: fixtures)

        #expect(verification.status == .verified)
        #expect(verification.verifiedCount == Self.clips.count)
        #expect(verification.issues.isEmpty, "\(verification.issues)")
    }

    /// Format- and depth-agnostic: a doppelganger manifest kept under a
    /// non-generated name in a subfolder of the folder it describes is the
    /// reference, not an added file.
    @Test func renamedManifestInsideTheFolderIsNotAnAddedFile() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let copy = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("copy-spool")
        )
        #expect(copy.report.status == .verified)
        let reports = destination.appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let reference = reports.appendingPathComponent("CardA-offload-record.json")
        try FileManager.default.copyItem(
            at: destination.appendingPathComponent(
                ManifestWriter.manifestFileName(shortID: copy.report.shortID)
            ),
            to: reference
        )

        let verification = try await Self.verify(reference: reference, media: destination, fixtures: fixtures)

        #expect(verification.status == .verified)
        #expect(verification.verifiedCount == EngineHarness.standardFiles.count)
        #expect(verification.issues.isEmpty, "\(verification.issues)")
    }

    /// Setting the reference aside never hides a gap: with a listed clip
    /// removed, the run fails on that clip and reports nothing added.
    @Test func missingClipStillFailsWithTheReferenceInsideTheFolder() async throws {
        let fixtures = try FixtureBuilder()
        let media = try fixtures.makeCard(named: "CardA", files: Self.clips)
        let reference = media.appendingPathComponent(Self.referenceName)
        try Self.mhlV1(Self.clips).write(to: reference)
        try FileManager.default.removeItem(at: media.appendingPathComponent(Self.clips[1].path))

        let verification = try await Self.verify(reference: reference, media: media, fixtures: fixtures)

        #expect(verification.status == .failed)
        #expect(verification.verifiedCount == 1)
        #expect(verification.issues.isEmpty, "\(verification.issues)")
        #expect(verification.outcome(Self.clips[1].path, at: media) == .failed(.missingFile))
    }
}
