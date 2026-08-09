import Foundation
import Testing
@testable import Doppelganger

/// Cancellation is a defined interruption: the manifest is still written, the
/// stream still ends with `.finished`, and nothing unverified is ever reported
/// as success.
struct EngineCancellationTests {
    private static let files: [FixtureBuilder.FileSpec] = [
        .init("DCIM/100MEDIA/big.bin", size: 2_000_000, seed: 10),
        .init("zz/small-1.bin", size: 10_000, seed: 11),
        .init("zz/small-2.bin", size: 10_000, seed: 12),
    ]

    @Test func cancelMidCopyCleansPartialsAndWritesManifest() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.files)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let spool = fixtures.root.appendingPathComponent("spool")
        let sourceBefore = try fixtures.digestSnapshot(of: card)

        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.delayWrites(microseconds: 2_000) // keep the copy pass open long enough to land the cancel

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB], spool: spool,
            chunkSize: 16 * 1024,
            cancelWhen: { event in
                if case .progress(let progress) = event {
                    return progress.phase == .copying && progress.copiedBytes > 64 * 1024
                }
                return false
            })

        #expect(run.report.status == .cancelled)
        // Copied-but-unverified is not success: nothing may be verified.
        #expect(run.report.verifiedCount == 0)
        for item in run.report.items {
            for outcome in item.outcomes.values {
                #expect(outcome == .failed(.cancelled) || outcome == .skipped(.cancelled))
            }
        }
        // The in-flight partials were removed from both destinations.
        for destination in [destA, destB] {
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("DCIM/100MEDIA/big.bin").path))
        }
        // The interruption produced a manifest, not silence.
        let spoolTarget = try #require(run.report.spoolLocation)
        let manifest = try EngineHarness.decodeManifest(at: spoolTarget, shortID: run.report.shortID)
        #expect(manifest.status == "cancelled")
        #expect(try fixtures.digestSnapshot(of: card) == sourceBefore)
    }

    @Test func cancelMidVerifyLeavesNoPairWithoutAnOutcome() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.files)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let spool = fixtures.root.appendingPathComponent("spool")

        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.delayReads(microseconds: 1_000) // stretch the verify pass

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB], spool: spool,
            chunkSize: 16 * 1024,
            cancelWhen: { event in
                if case .phaseChanged(.verifying) = event { return true }
                return false
            })

        #expect(run.report.status == .cancelled)
        // Every pair has an explicit outcome; unverified pairs are skips,
        // never implicit successes.
        for item in run.report.items {
            for destination in [destA, destB] {
                let outcome = item.outcomes[destination]
                #expect(outcome != nil, "\(item.item.relativePath) at \(destination.path)")
                if outcome?.isVerified != true {
                    #expect(outcome == .skipped(.cancelled) || outcome == .failed(.cancelled))
                }
            }
        }
        // At least one copied pair was interrupted before verification.
        #expect(run.report.skippedCount > 0)
        let spoolTarget = try #require(run.report.spoolLocation)
        #expect(try EngineHarness.decodeManifest(at: spoolTarget, shortID: run.report.shortID).status == "cancelled")
    }
}
