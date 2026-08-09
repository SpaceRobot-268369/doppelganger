import Foundation
import Testing
@testable import Doppelganger

struct EngineHappyPathTests {
    @Test func singleDestinationTransferVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")
        let spool = fixtures.root.appendingPathComponent("spool")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination], spool: spool)

        #expect(run.report.status == .verified)
        #expect(run.report.verifiedCount == 3)
        #expect(run.report.failedCount == 0)
        #expect(run.report.skippedCount == 0)

        // Bytes landed intact, nested relative paths preserved.
        for spec in EngineHarness.standardFiles {
            let copied = try fixtures.bytes(at: destination.appendingPathComponent(spec.path))
            #expect(copied == spec.bytes, "\(spec.path)")
        }

        // Manifest + Markdown report at the destination and in the spool.
        let shortID = run.report.shortID
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: shortID)
        #expect(manifest.status == "verified")
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(ManifestWriter.reportFileName(shortID: shortID)).path))
        let spoolTarget = try #require(run.report.spoolLocation)
        #expect(try EngineHarness.decodeManifest(at: spoolTarget, shortID: shortID) == manifest)
    }

    @Test func threeDestinationsAllVerifyIndependently() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destinations = [
            try fixtures.makeDestination(named: "dest-1"),
            try fixtures.makeDestination(named: "dest-2"),
            try fixtures.makeDestination(named: "dest-3"),
        ]
        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: destinations,
            spool: fixtures.root.appendingPathComponent("spool"))

        #expect(run.report.status == .verified)
        #expect(run.report.verifiedCount == 9)
        for destination in destinations {
            for spec in EngineHarness.standardFiles {
                #expect(run.report.outcome(spec.path, at: destination)?.isVerified == true)
            }
        }
        #expect(run.report.manifestLocations.count == 4) // 3 destinations + spool
    }

    @Test func manifestDigestsMatchIndependentRecomputation() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")
        let independentDigests = try fixtures.digestSnapshot(of: card)

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: run.report.shortID)
        #expect(manifest.items.count == 3)
        for item in manifest.items {
            #expect(item.digest == independentDigests[item.relativePath], "\(item.relativePath)")
        }
    }

    @Test func phasesArriveDistinctlyAndInOrder() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        // Copy finishing must hand off to a distinct verify phase — the UI can
        // never imply success at the end of copying.
        #expect(run.phases == [.enumerating, .copying, .verifying, .writingManifest, .done])
    }

    @Test func emptySourceFailsAndWritesOnlySpoolEvidence() async throws {
        let fixtures = try FixtureBuilder()
        let emptyCard = try fixtures.makeDestination(named: "empty-card")
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: emptyCard, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        #expect(run.report.status == .failed)
        #expect(run.report.items.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(
                ManifestWriter.manifestFileName(shortID: run.report.shortID)
            ).path
        ))
        let spoolTarget = try #require(run.report.spoolLocation)
        let manifest = try EngineHarness.decodeManifest(at: spoolTarget, shortID: run.report.shortID)
        #expect(manifest.status == "failed")
        #expect(manifest.summary.itemCount == 0)
    }

    @Test func zeroByteSourceFailsBeforeDestinationsAreTouched() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("valid.mov", size: 32, seed: 1),
            .init("empty.mov", size: 0, seed: 2),
        ])
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        #expect(run.report.status == .failed)
        #expect(run.report.outcome("empty.mov", at: destination) == .failed(.zeroByteSource))
        #expect(run.report.outcome("valid.mov", at: destination) == .skipped(.sourceUnavailable))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
