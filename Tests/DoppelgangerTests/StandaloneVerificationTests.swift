import Foundation
import Testing
@testable import Doppelganger

struct StandaloneVerificationTests {
    @Test func verifiesExistingDestinationFromPortableManifest() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let firstSpool = fixtures.root.appendingPathComponent("copy-spool")
        let copy = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: firstSpool,
            algorithm: .xxh3
        )
        let reference = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: copy.report.shortID)
        )

        let verification = try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: reference,
            mediaRoot: destination,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .verified)
        #expect(verification.verifiedCount == EngineHarness.standardFiles.count)
        #expect(verification.failedCount == 0)
        #expect(verification.manifestLocations.count == 1)
    }

    @Test func reportsDigestMismatchWithoutChangingExistingMedia() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let copy = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("copy-spool"),
            algorithm: .xxh3
        )
        let reference = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: copy.report.shortID)
        )
        let damaged = destination.appendingPathComponent(EngineHarness.standardFiles[0].path)
        var bytes = try Data(contentsOf: damaged)
        bytes[0] ^= 0xFF
        try bytes.write(to: damaged, options: .atomic)

        let verification = try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: reference,
            mediaRoot: destination,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: fixtures.root.appendingPathComponent("verify-spool")
        )

        #expect(verification.status == .failed)
        #expect(verification.failedCount == 1)
        if case .some(.failed(.checksumMismatch)) = verification.outcome(
            EngineHarness.standardFiles[0].path,
            at: destination
        ) {
            // Expected typed result.
        } else {
            Issue.record("Expected checksum mismatch")
        }
    }
}
