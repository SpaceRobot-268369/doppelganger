import Foundation
import Testing
@testable import Doppelganger

struct PauseResumeTests {
    @Test func pauseStopsAtFileBoundaryAndResumeDoesNotOverwriteVerifiedFiles() async throws {
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

        #expect(paused.report.status == .paused)
        #expect(paused.report.verifiedCount > 0)
        #expect(paused.report.verifiedCount < EngineHarness.standardFiles.count)
        let pausedManifest = try EngineHarness.decodeManifest(
            at: destination,
            shortID: paused.report.shortID
        )

        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("resume-spool"),
            resumeManifest: pausedManifest
        )

        #expect(resumed.report.status == .verified)
        #expect(resumed.report.verifiedCount == EngineHarness.standardFiles.count)
        #expect(resumed.report.failedCount == 0)
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
    }
}
