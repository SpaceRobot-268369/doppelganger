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
}
