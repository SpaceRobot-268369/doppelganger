import Foundation
import Testing
@testable import Doppelganger

struct FineGrainedRetryTests {
    @Test func retryRepairsOnlyFailedPairAndPreservesParentBytesAndEvidence() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let faulty = FailpointFileSystem(base: RealFileSystem())
        faulty.corruptFirstByteOnWrite(pathSuffix: "destination/DCIM/100MEDIA/a.bin")

        let failed = try await EngineHarness.run(
            fileSystem: faulty,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("failed-spool")
        )
        #expect(failed.report.status == .failed)
        let parentManifest = try EngineHarness.decodeManifest(
            at: destination,
            shortID: failed.report.shortID
        )
        let parentManifestURL = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: failed.report.shortID)
        )
        let parentEvidenceBefore = try Data(contentsOf: parentManifestURL)

        let repaired = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("retry-spool"),
            retryManifest: parentManifest,
            includedRelativePaths: ["DCIM/100MEDIA/a.bin"]
        )

        #expect(repaired.report.status == .verified)
        #expect(repaired.report.items.map(\.item.relativePath) == ["DCIM/100MEDIA/a.bin"])
        #expect(repaired.report.verifiedCount == 1)
        #expect(
            try fixtures.bytes(at: destination.appendingPathComponent("DCIM/100MEDIA/a.bin"))
                == fixtures.bytes(at: source.appendingPathComponent("DCIM/100MEDIA/a.bin"))
        )
        let quarantine = destination
            .appendingPathComponent(".doppelganger-failed")
            .appendingPathComponent(failed.report.shortID)
            .appendingPathComponent("DCIM/100MEDIA/a.bin")
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(try Data(contentsOf: parentManifestURL) == parentEvidenceBefore)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                ManifestWriter.manifestFileName(shortID: repaired.report.shortID)
            ).path
        ))
    }

    @Test func retryRefusesVerifiedPair() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let complete = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("complete-spool")
        )
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: complete.report.shortID)

        let refused = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("refused-spool"),
            retryManifest: manifest,
            includedRelativePaths: ["DCIM/100MEDIA/a.bin"]
        )

        #expect(refused.report.status == .failed)
        #expect(refused.report.issues.contains { $0.contains("does not authorize") })
    }
}
