import Foundation
import Testing
@testable import Doppelganger

struct VerificationProfileTests {
    @Test func fastTransferEndsYellowAndNeverClaimsVerified() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "fast-destination")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"),
            algorithm: .xxh3,
            verificationProfile: .fast
        )

        #expect(run.report.status == .transferredPendingVerification)
        #expect(run.report.pendingVerificationCount == EngineHarness.standardFiles.count)
        #expect(run.report.verifiedCount == 0)
        #expect(run.report.verificationProfile == .fast)
        let manifest = try EngineHarness.decodeManifest(
            at: destination,
            shortID: run.report.shortID
        )
        #expect(manifest.status == "transferredPendingVerification")
        #expect(manifest.summary.pendingVerificationCount == EngineHarness.standardFiles.count)
    }

    @Test func maximumIndependentlyPreReadsThenVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "maximum-destination")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"),
            algorithm: .xxh3,
            verificationProfile: .maximum
        )

        #expect(run.report.status == .verified)
        #expect(run.report.verifiedCount == EngineHarness.standardFiles.count)
        #expect(run.phases == [
            .enumerating, .preReadingSource, .copying, .verifying, .writingManifest, .done
        ])
    }

    @Test func maximumRequestsFullDurabilityForMediaAndStandardDoesNot() async throws {
        for (profile, expected) in [(VerificationProfile.maximum, WriteDurability.full),
                                    (.standard, .standard)] {
            let fixtures = try FixtureBuilder()
            let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
            let destination = try fixtures.makeDestination(named: "destination")
            let fs = FailpointFileSystem(base: RealFileSystem())

            let run = try await EngineHarness.run(
                fileSystem: fs,
                source: source,
                destinations: [destination],
                spool: fixtures.root.appendingPathComponent("spool"),
                verificationProfile: profile
            )

            #expect(run.report.status == .verified)
            for spec in EngineHarness.standardFiles {
                let target = destination.appendingPathComponent(spec.path)
                #expect(fs.requestedDurability(for: target) == expected, "\(profile) \(spec.path)")
            }
            // Evidence records are never the Maximum-durability path.
            let manifest = destination.appendingPathComponent(
                ManifestWriter.manifestFileName(shortID: run.report.shortID)
            )
            #expect(fs.requestedDurability(for: manifest) == .standard)
        }
    }

    @Test func maximumPreReadBytesReachTheFullPlan() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "maximum-destination")
        let totalBytes = EngineHarness.standardFiles.reduce(Int64(0)) { $0 + Int64($1.size) }

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"),
            verificationProfile: .maximum
        )

        #expect(run.report.status == .verified)
        let snapshots = run.events.compactMap { event -> TransferProgress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }
        let final = try #require(snapshots.last)
        // The independent pre-read is its own leg of the work budget; it
        // must report every byte, not just hash them silently.
        #expect(final.preReadBytes == totalBytes)
        #expect(final.copiedBytes == totalBytes)
        #expect(final.verifiedBytesByDestination[destination] == totalBytes)
        #expect(final.totalBytes == totalBytes)

        // Standard never pre-reads, so the counter stays at zero there.
        let standard = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [try fixtures.makeDestination(named: "standard-destination")],
            spool: fixtures.root.appendingPathComponent("standard-spool"),
            verificationProfile: .standard
        )
        let standardSnapshots = standard.events.compactMap { event -> TransferProgress? in
            if case .progress(let progress) = event { return progress }
            return nil
        }
        #expect(standardSnapshots.last?.preReadBytes == 0)
    }
}
