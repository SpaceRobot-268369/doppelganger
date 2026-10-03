import Darwin
import Foundation
import Testing
@testable import Doppelganger

/// verify-evidence-6 / engine-9: the fine-grained retry's quarantine tree
/// (`<output>/.doppelganger-failed/<parent>/<path>`) holds known-bad bytes.
/// It is evidence, never media: enumeration — and so preflight, the engine
/// plan, cascades and Verify Existing Media — must not see it.
/// Synthetic fixtures in a temp directory only.
struct RetryQuarantineEnumerationTests {
    private static let quarantineName = ".doppelganger-failed"

    /// A Standard offload whose a.bin write is corrupted (the parent fails that
    /// pair with a checksum mismatch), then the fine-grained repair of exactly
    /// that pair into the same output — the request AppModel.retryFailures builds.
    private static func makeRepairedOutput(
        in fixtures: FixtureBuilder
    ) async throws -> (source: URL, output: URL, quarantined: URL, parent: TransferReport) {
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let output = try fixtures.makeDestination(named: "destination")
        let faulty = FailpointFileSystem(base: RealFileSystem())
        faulty.corruptFirstByteOnWrite(pathSuffix: "destination/DCIM/100MEDIA/a.bin")

        let failed = try await EngineHarness.run(
            fileSystem: faulty,
            source: source,
            destinations: [output],
            spool: fixtures.root.appendingPathComponent("failed-spool")
        )
        try #require(failed.report.status == .failed)
        let parentManifest = try EngineHarness.decodeManifest(at: output, shortID: failed.report.shortID)

        let repaired = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [output],
            spool: fixtures.root.appendingPathComponent("retry-spool"),
            retryManifest: parentManifest,
            includedRelativePaths: ["DCIM/100MEDIA/a.bin"]
        )
        try #require(repaired.report.status == .verified)

        let quarantined = output
            .appendingPathComponent(quarantineName)
            .appendingPathComponent(failed.report.shortID)
            .appendingPathComponent("DCIM/100MEDIA/a.bin")
        // The engine really wrote the tree this suite is about.
        try #require(FileManager.default.fileExists(atPath: quarantined.path))
        return (source, output, quarantined, failed.report)
    }

    /// Port of Repro_G09.repro_quarantineTreeIsNotEnumeratedAsMedia, tightened
    /// to the exact ordered plan.
    @Test func repairedOutputEnumeratesOnlyMedia() async throws {
        let fixtures = try FixtureBuilder()
        let repaired = try await Self.makeRepairedOutput(in: fixtures)

        let plan = try RealFileSystem().enumerate(root: repaired.output).map(\.relativePath)

        #expect(plan == EngineHarness.standardFiles.map(\.path).sorted())
    }

    /// Port of Repro_G09.repro_verifyAfterRepairIgnoresQuarantineTree: Verify
    /// Again on the repaired folder against the parent's full manifest passes.
    @Test func verifyExistingAgainstParentManifestPassesAfterRepair() async throws {
        let fixtures = try FixtureBuilder()
        let repaired = try await Self.makeRepairedOutput(in: fixtures)
        let parentManifestURL = repaired.output.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: repaired.parent.shortID)
        )

        let verification = try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: parentManifestURL,
            mediaRoot: repaired.output,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.verifiedCount == EngineHarness.standardFiles.count)
        #expect(verification.issues.isEmpty, "\(verification.issues)")
        #expect(verification.status == .verified)
        // Verification only reads: the evidence is still where the engine put it.
        #expect(FileManager.default.fileExists(atPath: repaired.quarantined.path))
    }

    /// A cascade from the verified repair's output copies the media and never
    /// the quarantined bytes.
    @Test func cascadeFromRepairedOutputNeverCopiesQuarantinedBytes() async throws {
        let fixtures = try FixtureBuilder()
        let repaired = try await Self.makeRepairedOutput(in: fixtures)
        let quarantinedBefore = try fixtures.bytes(at: repaired.quarantined)
        let onward = try fixtures.makeDestination(named: "onward")

        let cascade = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: repaired.output,
            destinations: [onward],
            spool: fixtures.root.appendingPathComponent("cascade-spool")
        )

        #expect(cascade.report.status == .verified)
        #expect(
            cascade.report.items.map(\.item.relativePath).sorted()
                == EngineHarness.standardFiles.map(\.path).sorted()
        )
        #expect(!FileManager.default.fileExists(
            atPath: onward.appendingPathComponent(Self.quarantineName).path
        ))
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: onward.appendingPathComponent(spec.path)) == spec.bytes)
        }
        // The cascade source stays read-only, quarantine included.
        #expect(try fixtures.bytes(at: repaired.quarantined) == quarantinedBefore)
    }

    /// Only the engine's exact folder name is reserved, at any depth; hidden
    /// look-alikes and the unhidden name stay media.
    @Test func onlyTheExactQuarantineNameIsExcludedAtAnyDepth() throws {
        let fixtures = try FixtureBuilder()
        let root = try fixtures.makeCard(named: "shuttle", files: [
            .init("A001/A001C001.mov", size: 64, seed: 1),
            .init(".doppelganger-failed/1a2b3c4d/A001/A001C001.mov", size: 64, seed: 2),
            .init("CardB/B001/B001C001.mov", size: 64, seed: 3),
            .init("CardB/.doppelganger-failed/5e6f7a8b/B001/B001C001.mov", size: 64, seed: 4),
            .init(".doppelganger-failed-notes.txt", size: 8, seed: 5),
            .init("doppelganger-failed/clip.mov", size: 8, seed: 6),
            .init(".camera-settings", size: 8, seed: 7),
        ])

        #expect(try RealFileSystem().enumerate(root: root).map(\.relativePath) == [
            ".camera-settings",
            ".doppelganger-failed-notes.txt",
            "A001/A001C001.mov",
            "CardB/B001/B001C001.mov",
            "doppelganger-failed/clip.mov",
        ])
    }

    /// Choosing the quarantine folder itself as the source (deliberate
    /// recovery of the failed bytes) still lists its files: the reserved name
    /// is only matched below the chosen root.
    @Test func choosingTheQuarantineFolderItselfStillListsItsFiles() throws {
        let fixtures = try FixtureBuilder()
        let output = try fixtures.makeCard(named: "output", files: [
            .init("A001/A001C001.mov", size: 64, seed: 1),
            .init(".doppelganger-failed/1a2b3c4d/A001/A001C001.mov", size: 64, seed: 2),
        ])
        let quarantine = output.appendingPathComponent(Self.quarantineName, isDirectory: true)

        #expect(try RealFileSystem().enumerate(root: quarantine).map(\.relativePath)
            == ["1a2b3c4d/A001/A001C001.mov"])
        #expect(try RealFileSystem().enumerate(
            root: quarantine.appendingPathComponent("1a2b3c4d", isDirectory: true)
        ).map(\.relativePath) == ["A001/A001C001.mov"])
    }

    /// Merge guard for PR #6 (enumerate throws on unreadable folders outside
    /// known metadata): an unreadable quarantine must not block a scan of the
    /// output.
    @Test func unreadableQuarantineDoesNotBlockTheScan() throws {
        try #require(geteuid() != 0, "permission fixture is meaningless when running as root")
        let fixtures = try FixtureBuilder()
        let output = try fixtures.makeCard(named: "output", files: [
            .init("A001/A001C001.mov", size: 64, seed: 1),
            .init(".doppelganger-failed/1a2b3c4d/A001/A001C001.mov", size: 64, seed: 2),
        ])
        let locked = output.appendingPathComponent(".doppelganger-failed/1a2b3c4d", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            withExtendedLifetime(fixtures) {} // tear down only after unlocking
        }
        try #require(
            (try? FileManager.default.contentsOfDirectory(atPath: locked.path)) == nil,
            "fixture directory should be unreadable after chmod 000"
        )

        #expect(try RealFileSystem().enumerate(root: output).map(\.relativePath) == ["A001/A001C001.mov"])
    }
}
