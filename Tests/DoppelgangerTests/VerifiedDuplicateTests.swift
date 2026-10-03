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

    /// A destination that already holds a verified copy of most of the plan,
    /// with one file gone, so the duplicate flow proves two and copies one.
    private struct PartialDuplicateWorld {
        let fixtures: FixtureBuilder
        let source: URL
        let destination: URL
        let fingerprint: String
        let manifest: TransferManifest
        let fs: FailpointFileSystem
        let totalBytes: Int64
        let remainderBytes: Int64
        let reserve: Int64
    }

    private func makePartialDuplicateWorld() async throws -> PartialDuplicateWorld {
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
        #expect(first.report.status == .verified)
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: first.report.shortID)
        // b.bin vanished from the destination: it is the non-duplicate remainder.
        try FileManager.default.removeItem(at: destination.appendingPathComponent("DCIM/100MEDIA/b.bin"))
        let totalBytes = EngineHarness.standardFiles.reduce(Int64(0)) { $0 + Int64($1.size) }
        return PartialDuplicateWorld(
            fixtures: fixtures,
            source: source,
            destination: destination,
            fingerprint: fingerprint,
            manifest: manifest,
            fs: FailpointFileSystem(base: RealFileSystem()),
            totalBytes: totalBytes,
            remainderBytes: 150_000,
            reserve: TransferWorker.reserveBytes(for: totalBytes)
        )
    }

    @Test func partialDuplicateProceedsWhenTheRemainderFits() async throws {
        let world = try await makePartialDuplicateWorld()
        // Room for the remainder but not for the whole plan: the old
        // all-or-nothing check would have needed total + reserve.
        world.fs.overrideFreeSpace(at: world.destination, bytes: world.reserve + world.remainderBytes + 10_000)
        #expect(world.reserve + world.remainderBytes + 10_000 < world.totalBytes + world.reserve)

        let run = try await EngineHarness.run(
            fileSystem: world.fs,
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("second-spool"),
            sourceFingerprint: world.fingerprint,
            duplicateManifests: [world.destination.path: world.manifest]
        )

        #expect(run.report.status == .verified)
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destination) == .verifiedDuplicate)
        #expect(run.report.outcome("MISC/c.txt", at: world.destination) == .verifiedDuplicate)
        #expect(run.report.outcome("DCIM/100MEDIA/b.bin", at: world.destination) == .verified)
        #expect(try world.fixtures.bytes(at: world.destination.appendingPathComponent("DCIM/100MEDIA/b.bin"))
            == EngineHarness.standardFiles[1].bytes)
    }

    @Test func partialDuplicateFailsFullBeforeWritingWhenTheRemainderDoesNotFit() async throws {
        let world = try await makePartialDuplicateWorld()
        // The manifest still vouches for all three files, so the preflight
        // estimate passes; only the exact gate after duplicate verification
        // knows b.bin must actually be written.
        world.fs.overrideFreeSpace(at: world.destination, bytes: world.reserve + world.remainderBytes - 1)

        let run = try await EngineHarness.run(
            fileSystem: world.fs,
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("second-spool"),
            sourceFingerprint: world.fingerprint,
            duplicateManifests: [world.destination.path: world.manifest]
        )

        #expect(run.report.status == .failed)
        #expect(run.report.outcome("DCIM/100MEDIA/b.bin", at: world.destination) == .failed(.destinationFull))
        // The digest-proven duplicates keep their outcome; nothing was
        // overwritten with a blanket failure.
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destination) == .verifiedDuplicate)
        #expect(run.report.outcome("MISC/c.txt", at: world.destination) == .verifiedDuplicate)
        #expect(run.logMessages.contains { $0.contains("for the unverified remainder") })
        // Nothing was written: no b.bin, no staging leftovers.
        let mediaDirectory = world.destination.appendingPathComponent("DCIM/100MEDIA")
        let names = try FileManager.default.contentsOfDirectory(atPath: mediaDirectory.path)
        #expect(names.sorted() == ["a.bin"])
        #expect(!run.phases.contains(.copying) || run.events.allSatisfy {
            if case .progress(let progress) = $0 { return progress.copiedBytes == 0 }
            return true
        })
    }

    @Test func fullDuplicateNeedsNoWorkingSpace() async throws {
        let world = try await makePartialDuplicateWorld()
        // Put b.bin back: the prior manifest now covers the whole plan, so a
        // re-offload writes no media and must not demand the reserve.
        let restored = world.destination.appendingPathComponent("DCIM/100MEDIA/b.bin")
        try Data(EngineHarness.standardFiles[1].bytes).write(to: restored)
        world.fs.overrideFreeSpace(at: world.destination, bytes: 1)
        #expect(1 < world.reserve)

        let run = try await EngineHarness.run(
            fileSystem: world.fs,
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("second-spool"),
            sourceFingerprint: world.fingerprint,
            duplicateManifests: [world.destination.path: world.manifest]
        )

        #expect(run.report.status == .verified)
        for spec in EngineHarness.standardFiles {
            #expect(run.report.outcome(spec.path, at: world.destination) == .verifiedDuplicate)
        }
        #expect(!run.logMessages.contains { $0.contains("free, needs") })
    }

    @Test func preflightReservesAgainstTheUnprovenRemainder() async throws {
        let world = try await makePartialDuplicateWorld()
        // Downgrade b.bin in the prior manifest so it is not even a
        // candidate: the preflight estimate itself must then need room for
        // it, and fail the destination up front.
        var manifest = world.manifest
        for index in manifest.items.indices where manifest.items[index].relativePath == "DCIM/100MEDIA/b.bin" {
            manifest.items[index].results = manifest.items[index].results.map { result in
                var result = result
                result.status = "failed"
                return result
            }
        }
        #expect(TransferPreflight.duplicateCandidateBytes(
            items: try RealFileSystem().enumerate(root: world.source),
            manifest: manifest,
            output: world.destination
        ) == world.totalBytes - world.remainderBytes)
        world.fs.overrideFreeSpace(at: world.destination, bytes: world.reserve + world.remainderBytes - 1)

        let run = try await EngineHarness.run(
            fileSystem: world.fs,
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("second-spool"),
            sourceFingerprint: world.fingerprint,
            duplicateManifests: [world.destination.path: manifest]
        )

        #expect(run.report.status == .failed)
        for spec in EngineHarness.standardFiles {
            #expect(run.report.outcome(spec.path, at: world.destination) == .failed(.destinationFull))
        }
        #expect(!run.logMessages.contains { $0.contains("Verified duplicate skipped") })
    }
}
