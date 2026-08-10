import Foundation
import Testing
@testable import Doppelganger

/// The failure modes from `offload-model.md`, produced deterministically via
/// fault injection. Every test also asserts the source tree was untouched —
/// the read-only contract holds on every failure path.
struct EngineFailureTests {
    private struct World {
        let fixtures: FixtureBuilder
        let card: URL
        let destA: URL
        let destB: URL
        let spool: URL
        let fs: FailpointFileSystem
        let sourceBefore: [String: String]
    }

    private func makeWorld(files: [FixtureBuilder.FileSpec] = EngineHarness.standardFiles) throws -> World {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: files)
        return World(
            fixtures: fixtures,
            card: card,
            destA: try fixtures.makeDestination(named: "dest-a"),
            destB: try fixtures.makeDestination(named: "dest-b"),
            spool: fixtures.root.appendingPathComponent("spool"),
            fs: FailpointFileSystem(base: RealFileSystem()),
            sourceBefore: try fixtures.digestSnapshot(of: card)
        )
    }

    private func expectSourceUntouched(_ world: World) throws {
        #expect(try world.fixtures.digestSnapshot(of: world.card) == world.sourceBefore,
                "source must never be modified")
    }

    @Test func corruptedDestinationByteFailsExactlyThatPair() async throws {
        let world = try makeWorld()
        world.fs.corruptFirstByteOnWrite(pathSuffix: "dest-b/DCIM/100MEDIA/a.bin")

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        guard case .failed(.checksumMismatch(let expected, let actual))? =
                run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destB) else {
            Issue.record("expected checksum mismatch, got \(String(describing: run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destB)))")
            return
        }
        #expect(expected != actual)

        // Everything else verified — the failure is precise, not a blanket.
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destA)?.isVerified == true)
        for path in ["DCIM/100MEDIA/b.bin", "MISC/c.txt"] {
            #expect(run.report.outcome(path, at: world.destA)?.isVerified == true)
            #expect(run.report.outcome(path, at: world.destB)?.isVerified == true)
        }
        #expect(run.report.verifiedCount == 5)
        #expect(run.report.failedCount == 1)

        // The manifest records the mismatch, at both destinations and spool.
        let manifest = try EngineHarness.decodeManifest(at: world.destA, shortID: run.report.shortID)
        let badResult = manifest.items
            .first { $0.relativePath == "DCIM/100MEDIA/a.bin" }?
            .results.first { $0.destination == world.destB.path }
        #expect(badResult?.status == "failed")
        #expect(badResult?.reason == "checksum-mismatch")
        #expect(badResult?.actualDigest == actual)

        try expectSourceUntouched(world)
    }

    @Test func noSpaceMidCopyKillsDestinationSurvivorsComplete() async throws {
        let world = try makeWorld()
        // a.bin (200 kB) fits; b.bin trips ENOSPC partway through.
        world.fs.failWithNoSpace(under: world.destB, afterBytes: 250_000)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        // dest-a is untouched by dest-b's death.
        for spec in EngineHarness.standardFiles {
            #expect(run.report.outcome(spec.path, at: world.destA)?.isVerified == true)
        }
        // a.bin copied before the failure and still verified at dest-b.
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destB)?.isVerified == true)
        #expect(run.report.outcome("DCIM/100MEDIA/b.bin", at: world.destB) == .failed(.destinationFull))
        #expect(run.report.outcome("MISC/c.txt", at: world.destB) == .skipped(.destinationUnavailable))

        // The partial b.bin was cleaned off dest-b.
        #expect(!FileManager.default.fileExists(
            atPath: world.destB.appendingPathComponent("DCIM/100MEDIA/b.bin").path))

        try expectSourceUntouched(world)
    }

    @Test func destinationUnmountMidCopyIsTypedAndSurvivorsComplete() async throws {
        let world = try makeWorld()
        world.fs.markVolumeGoneAfterWriting(bytes: 250_000, under: world.destB)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        for spec in EngineHarness.standardFiles {
            #expect(run.report.outcome(spec.path, at: world.destA)?.isVerified == true)
        }
        // b.bin died mid-write; a.bin copied earlier but the volume was gone
        // by verify time — copied-but-unverified is a failure, not a success.
        #expect(run.report.outcome("DCIM/100MEDIA/b.bin", at: world.destB) == .failed(.destinationUnmounted))
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destB) == .failed(.destinationUnmounted))
        #expect(run.report.outcome("MISC/c.txt", at: world.destB) == .skipped(.destinationUnavailable))

        // Manifest written everywhere still reachable — not the dead volume.
        #expect(run.report.manifestLocations.contains(world.destA))
        #expect(!run.report.manifestLocations.contains(world.destB))
        #expect(run.report.spoolLocation != nil)

        try expectSourceUntouched(world)
    }

    @Test func sourceUnmountMidCopyKeepsEarlierItemsVerified() async throws {
        let world = try makeWorld()
        // a.bin reads fully; the "card" vanishes during b.bin.
        world.fs.markVolumeGoneAfterReading(bytes: 250_000, under: world.card)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination)?.isVerified == true)
            #expect(run.report.outcome("DCIM/100MEDIA/b.bin", at: destination) == .failed(.sourceUnmounted))
            #expect(run.report.outcome("MISC/c.txt", at: destination) == .skipped(.sourceUnavailable))
        }
        // Partial b.bin cleaned from both destinations.
        for destination in [world.destA, world.destB] {
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("DCIM/100MEDIA/b.bin").path))
        }
        // The interruption still produced manifests everywhere reachable.
        #expect(run.report.manifestLocations.contains(world.destA))
        #expect(run.report.manifestLocations.contains(world.destB))
    }

    @Test func unreadableSourceFileFailsOnlyThatItem() async throws {
        let world = try makeWorld()
        world.fs.markUnreadable(pathSuffix: "card/DCIM/100MEDIA/b.bin")

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination)?.isVerified == true)
            #expect(run.report.outcome("MISC/c.txt", at: destination)?.isVerified == true)
            guard case .failed(.sourceUnreadable)? = run.report.outcome("DCIM/100MEDIA/b.bin", at: destination) else {
                Issue.record("expected sourceUnreadable at \(destination.path)")
                return
            }
        }
        try expectSourceUntouched(world)
    }

    @Test func nameCollisionNeverOverwritesTheExistingFile() async throws {
        let world = try makeWorld()
        let collisionURL = world.destA.appendingPathComponent("DCIM/100MEDIA/a.bin")
        try FileManager.default.createDirectory(
            at: collisionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9, 9, 9]).write(to: collisionURL)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destA) == .failed(.nameCollision))
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destB)?.isVerified == true)
        // The pre-existing file is exactly as it was.
        #expect(try world.fixtures.bytes(at: collisionURL) == [9, 9, 9])
        try expectSourceUntouched(world)
    }

    @Test func freeSpacePreflightFailsTheDestinationUpFront() async throws {
        let world = try makeWorld()
        world.fs.overrideFreeSpace(at: world.destB, bytes: 10)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        for spec in EngineHarness.standardFiles {
            #expect(run.report.outcome(spec.path, at: world.destA)?.isVerified == true)
            #expect(run.report.outcome(spec.path, at: world.destB) == .failed(.destinationFull))
        }
        // Nothing was copied to the full destination.
        #expect(!FileManager.default.fileExists(
            atPath: world.destB.appendingPathComponent("DCIM/100MEDIA/a.bin").path))
    }

    @Test func destinationInsideSourceIsRefusedBeforeTouchingAnything() async throws {
        let world = try makeWorld()
        let nested = world.card.appendingPathComponent("backup")

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [nested], spool: world.spool)

        #expect(run.report.status == .failed)
        #expect(run.report.items.isEmpty)
        #expect(run.logMessages.contains { $0.contains("inside the source") })
        // Nothing was written into the source; spool still got the record.
        try expectSourceUntouched(world)
        #expect(run.report.manifestLocations.count == 1)
        #expect(run.report.spoolLocation != nil)
    }

    @Test func evidenceWriteFailureDowngradesVerifiedCopiesToFailedTransfer() async throws {
        let world = try makeWorld()
        world.fs.failEvidenceWrites(under: world.destB)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        #expect(run.report.verifiedCount == EngineHarness.standardFiles.count * 2)
        #expect(run.report.issues.contains { $0.contains(world.destB.path) })

        let destinationManifest = try EngineHarness.decodeManifest(
            at: world.destA, shortID: run.report.shortID)
        let spool = try #require(run.report.spoolLocation)
        let spoolManifest = try EngineHarness.decodeManifest(at: spool, shortID: run.report.shortID)
        #expect(destinationManifest.status == "failed")
        #expect(spoolManifest.status == "failed")
        #expect(!FileManager.default.fileExists(
            atPath: world.destA.appendingPathComponent(
                MHLWriter.fileName(shortID: run.report.shortID)
            ).path
        ))
        try expectSourceUntouched(world)
    }

    @Test func sourceChangeNeverPublishesTheStagedFile() async throws {
        let world = try makeWorld()
        world.fs.markSourceChanged(pathSuffix: "DCIM/100MEDIA/a.bin")

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool)

        #expect(run.report.status == .failed)
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination) == .failed(.sourceChanged))
            let final = destination.appendingPathComponent("DCIM/100MEDIA/a.bin")
            #expect(!FileManager.default.fileExists(atPath: final.path))
            let parent = final.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            #expect(!names.contains { $0.hasPrefix(".doppelganger-partial-") })
        }
        try expectSourceUntouched(world)
    }
}
