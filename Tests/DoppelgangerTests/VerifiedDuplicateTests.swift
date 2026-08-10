import Foundation
import Testing
@testable import Doppelganger

struct VerifiedDuplicateTests {
    @Test func independentlyMatchingExistingFilesAreSkippedWithoutRewrite() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: first.report.shortID)
        let target = destination.appendingPathComponent("DCIM/100MEDIA/a.bin")
        let before = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let duplicate = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("duplicate-spool"),
            sourceFingerprint: fingerprint,
            duplicateManifests: [destination.path: manifest]
        )

        #expect(duplicate.report.status == .verified)
        #expect(duplicate.report.items.allSatisfy {
            $0.outcomes[destination] == .verifiedDuplicate
        })
        #expect(duplicate.logMessages.filter { $0.contains("Verified duplicate skipped") }.count
            == EngineHarness.standardFiles.count)
        let after = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(before == after)
        let chain = try MHLReader.validateChain(
            at: destination.appendingPathComponent(MHLWriter.directoryName)
        )
        #expect(chain.entries.map(\.sequence) == [1, 2])
    }

    @Test func changedExistingFileIsNeverOverwrittenByDuplicateFlow() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: first.report.shortID)
        let changed = destination.appendingPathComponent("DCIM/100MEDIA/a.bin")
        var bytes = try Data(contentsOf: changed)
        bytes[0] ^= 0xFF
        try bytes.write(to: changed, options: .atomic)
        let changedBytes = try Data(contentsOf: changed)

        let refused = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("refused-spool"),
            sourceFingerprint: fingerprint,
            duplicateManifests: [destination.path: manifest]
        )

        #expect(refused.report.status == .failed)
        #expect(refused.report.outcome("DCIM/100MEDIA/a.bin", at: destination) == .failed(.nameCollision))
        #expect(try Data(contentsOf: changed) == changedBytes)
    }

    @Test func preflightTreatsPriorManifestAsCandidateNotProof() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let base = try fixtures.makeDestination(named: "base")
        let folderName = "A001"
        let output = base.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [output],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        #expect(first.report.status == .verified)

        let preflight = await TransferPreflight.inspect(
            source: source,
            destinationBases: [base],
            folderName: folderName,
            algorithm: .xxh64
        )

        #expect(preflight.canStart)
        #expect(preflight.destinations.first?.duplicateManifest != nil)
        #expect(preflight.notices.contains { $0.contains("hash source and destination independently") })
    }
}
