import Foundation
import Testing
@testable import Doppelganger

/// A fine-grained retry may set an existing destination file aside only on
/// proof that the parent attempt itself published those exact bytes: the
/// parent recorded a checksum mismatch for that path at that destination,
/// together with the digest it read back, and the file there still hashes to
/// that digest. Anything else at a retry target fails the pair as a name
/// collision and is never moved or overwritten (AGENTS.md Principle 3;
/// offload-model.md "Name collisions never overwrite a file").
///
/// Synthetic fixtures in a scratch directory only.
struct RetryQuarantineTests {
    // MARK: - Fixtures

    /// Two Sony-shaped cards. Card structure files and restarted clip numbers
    /// collide by relative path while holding different footage.
    static let cardAFiles: [FixtureBuilder.FileSpec] = [
        .init("PRIVATE/M4ROOT/MEDIAPRO.XML", size: 2_000, seed: 101),
        .init("PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 180_000, seed: 102),
        .init("PRIVATE/M4ROOT/CLIP/C0002.MP4", size: 120_000, seed: 103),
    ]
    static let cardBFiles: [FixtureBuilder.FileSpec] = [
        .init("PRIVATE/M4ROOT/MEDIAPRO.XML", size: 2_400, seed: 201),
        .init("PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 160_000, seed: 202),
        .init("PRIVATE/M4ROOT/CLIP/C0003.MP4", size: 90_000, seed: 203),
    ]
    static let collidingPaths = [
        "PRIVATE/M4ROOT/MEDIAPRO.XML",
        "PRIVATE/M4ROOT/CLIP/C0001.MP4",
    ]

    /// The same clip path on both cards with the SAME size and different
    /// footage, so size alone proves nothing about whose bytes are there.
    static let sameSizeClipPath = "PRIVATE/M4ROOT/CLIP/C0001.MP4"
    static let sameSizeCardAFiles: [FixtureBuilder.FileSpec] = [
        .init("PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 160_000, seed: 102),
        .init("PRIVATE/M4ROOT/CLIP/C0002.MP4", size: 120_000, seed: 103),
    ]
    static let sameSizeCardBFiles: [FixtureBuilder.FileSpec] = [
        .init("PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 160_000, seed: 202),
        .init("PRIVATE/M4ROOT/CLIP/C0003.MP4", size: 90_000, seed: 203),
    ]

    /// The standard-card file whose first written byte is corrupted to give
    /// the parent a genuine checksum mismatch.
    static let corruptedPath = "DCIM/100MEDIA/a.bin"

    /// A parent result at the retry target that does not prove the parent
    /// published the bytes there.
    struct UnprovenParentResult: Sendable, CustomTestStringConvertible {
        let status: String
        let reason: String?
        let actualDigest: String?

        var testDescription: String {
            "\(status)/\(reason ?? "-")/\(actualDigest == nil ? "no read-back" : "stale read-back")"
        }
    }

    static let unprovenParentResults: [UnprovenParentResult] = [
        .init(status: "failed", reason: "name-collision", actualDigest: nil),
        .init(status: "failed", reason: "destination-full", actualDigest: nil),
        .init(status: "failed", reason: "destination-unmounted", actualDigest: nil),
        .init(status: "failed", reason: "write-failed", actualDigest: nil),
        .init(status: "failed", reason: "cancelled", actualDigest: nil),
        .init(status: "failed", reason: "source-changed", actualDigest: nil),
        .init(status: "skipped", reason: "cancelled", actualDigest: nil),
        .init(status: "skipped", reason: "paused", actualDigest: nil),
        .init(status: "skipped", reason: "destination-unavailable", actualDigest: nil),
        .init(status: "transferred-pending-verification", reason: "destination-readback-required", actualDigest: nil),
        .init(status: "failed", reason: "checksum-mismatch", actualDigest: nil),
        .init(status: "failed", reason: "checksum-mismatch", actualDigest: "0000000000000000"),
    ]

    // MARK: - Helpers

    private static func run(_ request: TransferRequest) async throws -> TransferReport {
        let engine = TransferEngine(
            fileSystem: RealFileSystem(),
            configuration: TransferConfiguration(chunkSize: 64 * 1024, progressInterval: .milliseconds(1))
        )
        var report: TransferReport?
        for await event in await engine.run(request) {
            if case .finished(let finished) = event { report = finished }
        }
        return try #require(report, "stream must end with .finished")
    }

    /// Exactly the scope `AppModel.retryFailures` builds for one destination.
    private static func failedPaths(_ report: TransferReport, at destination: URL) -> Set<String> {
        Set(report.items.compactMap { item -> String? in
            if case .failed = item.outcomes[destination] { return item.item.relativePath }
            return nil
        })
    }

    private static func manifest(of report: TransferReport) throws -> TransferManifest {
        try EngineHarness.decodeManifest(at: try #require(report.spoolLocation), shortID: report.shortID)
    }

    private static func xxh64(of url: URL) throws -> String {
        var hasher = ChecksumAlgorithm.xxh64.makeHasher()
        let bytes = [UInt8](try Data(contentsOf: url))
        bytes.withUnsafeBytes { hasher.update($0) }
        return hasher.hexDigest()
    }

    /// The verified evidence of `manifest` still describes the bytes at
    /// `output/relativePath`.
    private static func evidenceStillHolds(
        _ manifest: TransferManifest,
        relativePath: String,
        output: URL
    ) throws -> Bool {
        let record = try #require(manifest.items.first { $0.relativePath == relativePath })
        let recorded = try #require(record.digest)
        return try xxh64(of: output.appendingPathComponent(relativePath)) == recorded
    }

    /// True when no quarantine tree was ever created under `destination`.
    private static func nothingQuarantined(at destination: URL) -> Bool {
        !FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(".doppelganger-failed").path
        )
    }

    /// A parent attempt that published corrupted bytes for `corruptedPath`
    /// and recorded the checksum mismatch it read back.
    private struct ChecksumMismatchParent {
        let source: URL
        let destination: URL
        let report: TransferReport
        let manifest: TransferManifest
        /// The digest the parent read back from its own published copy.
        let readBack: String
    }

    private static func makeChecksumMismatchParent(
        _ fixtures: FixtureBuilder
    ) async throws -> ChecksumMismatchParent {
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let faulty = FailpointFileSystem(base: RealFileSystem())
        faulty.corruptFirstByteOnWrite(pathSuffix: "destination/" + Self.corruptedPath)

        let parent = try await EngineHarness.run(
            fileSystem: faulty,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("parent-spool")
        )
        try #require(parent.report.status == .failed)
        let parentManifest = try Self.manifest(of: parent.report)
        let record = try #require(parentManifest.items.first { $0.relativePath == Self.corruptedPath })
        let result = try #require(record.results.first { $0.destination == destination.path })
        try #require(result.status == "failed")
        try #require(result.reason == "checksum-mismatch")
        let readBack = try #require(result.actualDigest, "the parent must record what it read back")
        // The parent's read-back describes exactly the bytes it left on disk.
        try #require(try Self.xxh64(of: destination.appendingPathComponent(Self.corruptedPath)) == readBack)
        return ChecksumMismatchParent(
            source: source,
            destination: destination,
            report: parent.report,
            manifest: parentManifest,
            readBack: readBack
        )
    }

    // MARK: - Collisions with another task's verified files

    /// Card B collides with card A's verified files at copy time (the engine
    /// correctly refuses to overwrite them). Retrying card B's failures must
    /// not move card A's verified files away and publish card B's bytes at
    /// card A's verified paths.
    @Test func retryAfterCopyCollisionKeepsOtherTasksVerifiedFiles() async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(named: "SONY_A", files: Self.cardAFiles)
        let cardB = try fixtures.makeCard(named: "SONY_B", files: Self.cardBFiles)
        let destination = try fixtures.makeDestination(named: "shuttle")

        let runA = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardA,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-a")
        )
        #expect(runA.report.status == .verified)
        let manifestA = try Self.manifest(of: runA.report)
        let manifestAURL = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: runA.report.shortID)
        )
        let manifestAEvidenceBefore = try Data(contentsOf: manifestAURL)

        let runB = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardB,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-b")
        )
        #expect(runB.report.status == .failed)
        for path in Self.collidingPaths {
            #expect(runB.report.outcome(path, at: destination) == .failed(.nameCollision), "\(path)")
        }
        let scope = Self.failedPaths(runB.report, at: destination)
        #expect(scope == Set(Self.collidingPaths))

        let retry = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardB,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-retry"),
            retryManifest: try Self.manifest(of: runB.report),
            includedRelativePaths: scope
        )

        for path in Self.collidingPaths {
            // Card A's verified copy is still at its verified path …
            #expect(
                try fixtures.bytes(at: destination.appendingPathComponent(path))
                    == fixtures.bytes(at: cardA.appendingPathComponent(path)),
                "\(path): card A's verified file was displaced"
            )
            // … so card A's Verified evidence still describes what is on disk.
            #expect(try Self.evidenceStillHolds(manifestA, relativePath: path, output: destination), "\(path)")
            #expect(retry.report.outcome(path, at: destination) == .failed(.nameCollision), "\(path)")
        }
        // Nothing the parent wrote existed at those paths; nothing may be
        // quarantined, and a collision cannot be repaired into Verified.
        #expect(Self.nothingQuarantined(at: destination))
        #expect(retry.report.status == .failed)
        #expect(try Data(contentsOf: manifestAURL) == manifestAEvidenceBefore)
    }

    /// New-folder variant: card B was reviewed against the same transfer
    /// folder before card A created it, so its whole destination fails with
    /// `name-collision` at engine preflight. Retrying card B (which
    /// `TransferSession.start` runs with `requireNewOutputRoots == false`)
    /// must not quarantine card A's verified files.
    @Test func retryAfterWholeFolderCollisionKeepsEarlierTasksVerifiedFiles() async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(named: "SONY_A", files: Self.cardAFiles)
        let cardB = try fixtures.makeCard(named: "SONY_B", files: Self.cardBFiles)
        let base = try fixtures.makeDestination(named: "archive")
        let output = base.appendingPathComponent("20261002_A001", isDirectory: true)
        let destinations = [TransferDestination(baseRoot: base, outputRoot: output)]

        let reportA = try await Self.run(TransferRequest(
            sourceRoot: cardA,
            destinations: destinations,
            algorithm: .xxh64,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-a"),
            allowSameVolume: true,
            requireNewOutputRoots: true
        ))
        #expect(reportA.status == .verified)
        let manifestA = try Self.manifest(of: reportA)

        let reportB = try await Self.run(TransferRequest(
            sourceRoot: cardB,
            destinations: destinations,
            algorithm: .xxh64,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-b"),
            allowSameVolume: true,
            requireNewOutputRoots: true
        ))
        #expect(reportB.status == .failed)
        for spec in Self.cardBFiles {
            #expect(reportB.outcome(spec.path, at: output) == .failed(.nameCollision), "\(spec.path)")
        }
        let scope = Self.failedPaths(reportB, at: output)
        #expect(!scope.isEmpty)

        let retry = try await Self.run(TransferRequest(
            sourceRoot: cardB,
            destinations: destinations,
            algorithm: .xxh64,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-retry"),
            allowSameVolume: true,
            requireNewOutputRoots: false,
            retryManifest: try Self.manifest(of: reportB),
            includedRelativePaths: scope
        ))

        for path in Self.collidingPaths {
            #expect(
                try fixtures.bytes(at: output.appendingPathComponent(path))
                    == fixtures.bytes(at: cardA.appendingPathComponent(path)),
                "\(path): card A's verified file was displaced"
            )
            #expect(try Self.evidenceStillHolds(manifestA, relativePath: path, output: output), "\(path)")
            #expect(retry.outcome(path, at: output) == .failed(.nameCollision), "\(path)")
        }
        #expect(Self.nothingQuarantined(at: output))
        #expect(retry.status == .failed)
        // C0003 is deliberately not asserted: whether a whole-folder collision
        // retry may write non-colliding files into another task's folder
        // belongs to the batch folder-name uniqueness finding.
    }

    /// The exact path a "Directly in destination" batch of two cards takes:
    /// both first attempts are built the way `TransferSession.start` builds
    /// them (output root == base, `requireNewOutputRoots == true`), then the
    /// operator clicks Retry on each card in turn. Card A must keep its
    /// verified bytes and evidence after card B's retry.
    @Test func directLayoutBatchRetriesDoNotSwapVerifiedCards() async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(named: "SONY_A", files: Self.cardAFiles)
        let cardB = try fixtures.makeCard(named: "SONY_B", files: Self.cardBFiles)
        let base = try fixtures.makeDestination(named: "shuttle")
        let direct = [TransferDestination(baseRoot: base, outputRoot: base)]

        func firstAttempt(_ source: URL, spool: String) async throws -> TransferReport {
            try await Self.run(TransferRequest(
                sourceRoot: source,
                destinations: direct,
                algorithm: .xxh64,
                spoolDirectory: fixtures.root.appendingPathComponent(spool),
                allowSameVolume: true,
                requireNewOutputRoots: true
            ))
        }
        func retryFailures(of parent: TransferReport, source: URL, spool: String) async throws -> TransferReport? {
            let scope = Self.failedPaths(parent, at: base)
            guard !scope.isEmpty else { return nil }
            return try await Self.run(TransferRequest(
                sourceRoot: source,
                destinations: direct,
                algorithm: .xxh64,
                spoolDirectory: fixtures.root.appendingPathComponent(spool),
                allowSameVolume: true,
                requireNewOutputRoots: false,
                retryManifest: try Self.manifest(of: parent),
                includedRelativePaths: scope
            ))
        }

        // Batch: both cards were reviewed before either wrote anything, and
        // the scheduler runs them one after the other on the shared volume.
        let firstA = try await firstAttempt(cardA, spool: "spool-a1")
        let firstB = try await firstAttempt(cardB, spool: "spool-b1")

        // Operator repairs card A first; card A ends up Verified (through its
        // retry, or through its first attempt once direct layout allows it).
        let verifiedA = try await retryFailures(of: firstA, source: cardA, spool: "spool-a2") ?? firstA
        #expect(verifiedA.status == .verified)
        let manifestA = try Self.manifest(of: verifiedA)

        // Then repairs card B.
        let retryOfB = try await retryFailures(of: firstB, source: cardB, spool: "spool-b2")
        let retryB = try #require(retryOfB, "card B's colliding paths must be in its retry scope")

        for path in Self.collidingPaths {
            #expect(
                try fixtures.bytes(at: base.appendingPathComponent(path))
                    == fixtures.bytes(at: cardA.appendingPathComponent(path)),
                "\(path): card A still reads Verified but its file was swapped for card B's"
            )
            #expect(try Self.evidenceStillHolds(manifestA, relativePath: path, output: base), "\(path)")
            #expect(retryB.outcome(path, at: base) == .failed(.nameCollision), "\(path)")
        }
        #expect(retryB.status == .failed)
        #expect(Self.nothingQuarantined(at: base))
    }

    // MARK: - Allowlist plus proof

    /// Whatever the parent recorded at the target, unless it is a checksum
    /// mismatch whose read-back digest matches the file there now, the retry
    /// may not move that file. Card A's same-size clip stays exactly where it
    /// is and the pair fails as a collision.
    @Test(arguments: RetryQuarantineTests.unprovenParentResults)
    func retryNeverMovesATargetTheParentCannotProveItWrote(_ arg: UnprovenParentResult) async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(named: "SONY_A", files: Self.sameSizeCardAFiles)
        let cardB = try fixtures.makeCard(named: "SONY_B", files: Self.sameSizeCardBFiles)
        let destination = try fixtures.makeDestination(named: "shuttle")
        let path = Self.sameSizeClipPath

        let runA = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardA,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-a")
        )
        try #require(runA.report.status == .verified)
        let manifestA = try Self.manifest(of: runA.report)

        let runB = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardB,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-b")
        )
        try #require(runB.report.outcome(path, at: destination) == .failed(.nameCollision))
        // Same size on disk, different footage: size alone cannot tell them apart.
        try #require(try fixtures.bytes(at: destination.appendingPathComponent(path)).count == 160_000)
        try #require(try fixtures.bytes(at: cardB.appendingPathComponent(path)).count == 160_000)

        var parent = try Self.manifest(of: runB.report)
        let i = try #require(parent.items.firstIndex { $0.relativePath == path })
        let j = try #require(parent.items[i].results.firstIndex { $0.destination == destination.path })
        try #require(parent.items[i].results[j].reason == "name-collision")
        parent.items[i].results[j].status = arg.status
        parent.items[i].results[j].reason = arg.reason
        parent.items[i].results[j].detail = nil
        parent.items[i].results[j].actualDigest = arg.actualDigest

        let retry = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardB,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool-retry"),
            retryManifest: parent,
            includedRelativePaths: [path]
        )

        #expect(
            try fixtures.bytes(at: destination.appendingPathComponent(path))
                == fixtures.bytes(at: cardA.appendingPathComponent(path)),
            "\(arg.testDescription): card A's verified file was displaced"
        )
        #expect(try Self.evidenceStillHolds(manifestA, relativePath: path, output: destination))
        #expect(Self.nothingQuarantined(at: destination))
        #expect(retry.report.outcome(path, at: destination) == .failed(.nameCollision))
        #expect(retry.report.status == .failed)
    }

    /// After a destination outage the parent never wrote driveB. Repair #1
    /// verifies every file there. A second repair from the same parent (the
    /// Retry button clicked again) must not displace repair #1's verified
    /// copies: it proves them identical to the source and keeps them in place,
    /// writing nothing, even on a drive with no room for another copy.
    @Test func duplicateRepairAfterDestinationOutageKeepsTheFirstRepairInPlace() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let driveA = try fixtures.makeDestination(named: "drive-a")
        let driveB = try fixtures.makeDestination(named: "drive-b")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))

        let unplugged = FailpointFileSystem(base: RealFileSystem())
        unplugged.markVolumeGone(driveB)
        let parent = try await EngineHarness.run(
            fileSystem: unplugged,
            source: source,
            destinations: [driveA, driveB],
            spool: fixtures.root.appendingPathComponent("parent-spool"),
            sourceFingerprint: fingerprint
        )
        try #require(parent.report.status == .failed)
        let parentManifest = try EngineHarness.decodeManifest(at: driveA, shortID: parent.report.shortID)
        for spec in EngineHarness.standardFiles {
            try #require(parent.report.outcome(spec.path, at: driveB) == .failed(.destinationUnmounted))
        }
        // AppModel.retryFailures: one repair per destination, scoped to the
        // failed paths there, fingerprint from the parent manifest.
        let scope = Self.failedPaths(parent.report, at: driveB)
        try #require(scope.count == EngineHarness.standardFiles.count)

        let repair1 = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [driveB],
            spool: fixtures.root.appendingPathComponent("repair-1-spool"),
            sourceFingerprint: parentManifest.sourceFingerprint,
            retryManifest: parentManifest,
            includedRelativePaths: scope
        )
        try #require(repair1.report.status == .verified)
        let repair1Manifest = try Self.manifest(of: repair1.report)

        // The same Retry button, clicked again; this time the drive fills.
        let filling = FailpointFileSystem(base: RealFileSystem())
        filling.failWithNoSpace(under: driveB, afterBytes: 100_000)
        let repair2 = try await EngineHarness.run(
            fileSystem: filling,
            source: source,
            destinations: [driveB],
            spool: fixtures.root.appendingPathComponent("repair-2-spool"),
            sourceFingerprint: parentManifest.sourceFingerprint,
            retryManifest: parentManifest,
            includedRelativePaths: scope
        )

        #expect(repair2.report.status == .verified)
        for spec in EngineHarness.standardFiles {
            #expect(repair2.report.outcome(spec.path, at: driveB) == .verifiedDuplicate, "\(spec.path)")
            #expect(
                try fixtures.bytes(at: driveB.appendingPathComponent(spec.path)) == spec.bytes,
                "\(spec.path): repair #1's verified copy was displaced"
            )
            #expect(
                try Self.evidenceStillHolds(repair1Manifest, relativePath: spec.path, output: driveB),
                "\(spec.path)"
            )
        }
        #expect(Self.nothingQuarantined(at: driveB))
    }

    // MARK: - The one authorized move

    /// Positive control: a parent that published corrupt bytes and read them
    /// back may have exactly those bytes set aside once. A second repair from
    /// the same parent finds the target holding repair #1's verified copy:
    /// it proves that copy identical to the source and keeps it, moving
    /// nothing and leaving the quarantined bytes as they were.
    @Test func retryQuarantinesOnlyTheParentsOwnReadBackAndOnlyOnce() async throws {
        let fixtures = try FixtureBuilder()
        let parent = try await Self.makeChecksumMismatchParent(fixtures)
        let target = parent.destination.appendingPathComponent(Self.corruptedPath)
        let quarantined = parent.destination
            .appendingPathComponent(".doppelganger-failed")
            .appendingPathComponent(parent.report.shortID)
            .appendingPathComponent(Self.corruptedPath)

        let repair1 = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: parent.source,
            destinations: [parent.destination],
            spool: fixtures.root.appendingPathComponent("repair-1-spool"),
            retryManifest: parent.manifest,
            includedRelativePaths: [Self.corruptedPath]
        )
        #expect(repair1.report.status == .verified)
        #expect(repair1.report.items.map(\.item.relativePath) == [Self.corruptedPath])
        #expect(try Self.xxh64(of: quarantined) == parent.readBack)
        #expect(
            try fixtures.bytes(at: target)
                == fixtures.bytes(at: parent.source.appendingPathComponent(Self.corruptedPath))
        )
        let repair1Manifest = try Self.manifest(of: repair1.report)

        let repair2 = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: parent.source,
            destinations: [parent.destination],
            spool: fixtures.root.appendingPathComponent("repair-2-spool"),
            retryManifest: parent.manifest,
            includedRelativePaths: [Self.corruptedPath]
        )
        #expect(repair2.report.status == .verified)
        #expect(repair2.report.outcome(Self.corruptedPath, at: parent.destination) == .verifiedDuplicate)
        #expect(
            try Self.evidenceStillHolds(repair1Manifest, relativePath: Self.corruptedPath, output: parent.destination)
        )
        #expect(
            try fixtures.bytes(at: target)
                == fixtures.bytes(at: parent.source.appendingPathComponent(Self.corruptedPath))
        )
        // The parent's failed bytes are still the ones set aside, not replaced.
        #expect(try Self.xxh64(of: quarantined) == parent.readBack)
    }

    /// Same checksum-mismatch parent, but the file at the target is no longer
    /// the one the parent read back (same size, different bytes). The slot is
    /// free, so only the digest check stands between the retry and a foreign
    /// file: it must refuse.
    @Test func retryRefusesWhenTheTargetNoLongerHoldsTheParentsFailedBytes() async throws {
        let fixtures = try FixtureBuilder()
        let parent = try await Self.makeChecksumMismatchParent(fixtures)
        let target = parent.destination.appendingPathComponent(Self.corruptedPath)

        // Scratch fixture only: something else now occupies the parent's path.
        let replacement = FixtureBuilder.FileSpec(Self.corruptedPath, size: 200_000, seed: 99)
        try FileManager.default.removeItem(at: target)
        try Data(replacement.bytes).write(to: target)
        try #require(try Self.xxh64(of: target) != parent.readBack)

        let retry = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: parent.source,
            destinations: [parent.destination],
            spool: fixtures.root.appendingPathComponent("retry-spool"),
            retryManifest: parent.manifest,
            includedRelativePaths: [Self.corruptedPath]
        )

        #expect(try fixtures.bytes(at: target) == replacement.bytes)
        #expect(Self.nothingQuarantined(at: parent.destination))
        #expect(retry.report.outcome(Self.corruptedPath, at: parent.destination) == .failed(.nameCollision))
        #expect(retry.report.status == .failed)
    }

    // MARK: - Published but never verified

    /// driveB disappears during the verify pass, after every file was
    /// published intact: the parent records them failed (destination
    /// unmounted) and cannot write its evidence there. Reconnected, a retry
    /// proves each existing copy identical to the source and keeps it in place
    /// (nothing moved, nothing rewritten), and the catalog task — which also
    /// holds driveA's copies, vouched for by the manifest that did land there
    /// — becomes Verified.
    @Test func retryKeepsPublishedButUnverifiedCopiesAndCompletesTheTask() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let driveA = try fixtures.makeDestination(named: "drive-a")
        let driveB = try fixtures.makeDestination(named: "drive-b")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))

        // Reads under driveB happen only in the verify pass; the first one
        // takes the drive away.
        let dropping = FailpointFileSystem(base: RealFileSystem())
        dropping.markVolumeGoneAfterReading(bytes: 1, under: driveB)
        let parent = try await EngineHarness.run(
            fileSystem: dropping,
            source: source,
            destinations: [driveA, driveB],
            spool: fixtures.root.appendingPathComponent("parent-spool"),
            sourceFingerprint: fingerprint
        )
        try #require(parent.report.status == .failed)
        try #require(parent.report.issues.contains {
            $0.hasPrefix(ProductDatabase.evidenceWriteIssuePrefix) && $0.contains(driveB.path)
        })
        for spec in EngineHarness.standardFiles {
            try #require(parent.report.outcome(spec.path, at: driveA) == .verified)
            guard case .failed? = parent.report.outcome(spec.path, at: driveB) else {
                Issue.record("expected \(spec.path) to fail at driveB"); return
            }
            // Published intact before the drive went away.
            try #require(try fixtures.bytes(at: driveB.appendingPathComponent(spec.path)) == spec.bytes)
        }
        let parentManifest = try EngineHarness.decodeManifest(at: driveA, shortID: parent.report.shortID)
        let scope = Self.failedPaths(parent.report, at: driveB)
        try #require(scope.count == EngineHarness.standardFiles.count)

        let repair = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [driveB],
            spool: fixtures.root.appendingPathComponent("repair-spool"),
            sourceFingerprint: parentManifest.sourceFingerprint,
            retryManifest: parentManifest,
            includedRelativePaths: scope
        )

        #expect(repair.report.status == .verified)
        for spec in EngineHarness.standardFiles {
            #expect(repair.report.outcome(spec.path, at: driveB) == .verifiedDuplicate, "\(spec.path)")
            #expect(try fixtures.bytes(at: driveB.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(Self.nothingQuarantined(at: driveB))

        // The catalog, fed exactly as AppModel feeds it.
        let database = try ProductDatabase(inMemory: true)
        let profile = try database.activeProfile()
        let taskID = UUID()
        try database.registerTask(
            id: taskID, label: "A001", source: source, destinations: [driveA, driveB],
            projectID: nil, operatorProfile: profile, algorithm: .xxh64, verificationProfile: .standard
        )
        let parentID = UUID()
        for (id, report, kind, parentAttempt) in [
            (parentID, parent.report, TransferAttemptKind.copy, UUID?.none),
            (UUID(), repair.report, .retry, parentID),
        ] {
            try database.registerAttempt(
                id: id, taskID: taskID, parentAttemptID: parentAttempt, kind: kind,
                operatorProfile: profile, algorithm: .xxh64,
                verificationProfile: report.verificationProfile, startedAt: report.startedAt
            )
            try database.finishAttempt(
                id: id, taskID: taskID, report: report, verificationProfile: report.verificationProfile
            )
        }
        let task = try #require(try database.taskHistory().first { $0.id == taskID })
        #expect(task.verdict == .verified)
        #expect(task.lifecycle == .complete)
    }
}
