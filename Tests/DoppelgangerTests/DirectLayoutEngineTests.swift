import Foundation
import Testing
@testable import Doppelganger

/// engine-2 / app-orchestration-2 / cross-cutting-1: "Directly in destination"
/// as the app actually starts it. `TransferSession.start()` builds the request
/// with the `destinations:` initializer and `requireNewOutputRoots` true for
/// every fresh offload, and a direct output root IS the destination base,
/// which always exists. The fresh-folder rule applies to task folders only;
/// a direct output is protected file by file and never overwrites.
///
/// Synthetic fixtures only (FixtureBuilder temp dir). `TransferSession` is not
/// constructed because its init writes a journal under Application Support;
/// the request mirrors the arguments `start()` passes instead.
struct DirectLayoutEngineTests {
    /// Multi-chunk at the 64 KiB test chunk size, like a real clip.
    private static let directCard: [FixtureBuilder.FileSpec] = [
        FixtureBuilder.FileSpec("DCIM/100/A001.MOV", size: 70_000, seed: 61),
        FixtureBuilder.FileSpec("DCIM/100/A002.MOV", size: 3_000, seed: 62),
    ]

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

    /// The request `TransferSession.start()` builds for a fresh offload from a
    /// reviewed preflight (`AppModel.startDraftOffloads`): `destinations:` init,
    /// no resume, no retry, duplicate candidates from the preflight. Keep the
    /// `requireNewOutputRoots` expression identical to TransferSession.swift.
    private static func appRequest(for preflight: TransferPreflight, spool: URL) -> TransferRequest {
        let duplicateManifests = Dictionary(uniqueKeysWithValues: preflight.destinations.compactMap { destination in
            destination.duplicateManifest.map { (destination.output.path, $0) }
        })
        let resumeManifest: TransferManifest? = nil
        let retryManifest: TransferManifest? = nil
        return TransferRequest(
            sourceRoot: preflight.source,
            destinations: preflight.requestDestinations,
            algorithm: .xxh3,
            verificationProfile: .standard,
            sourceFingerprint: preflight.sourceFingerprint,
            spoolDirectory: spool,
            allowSameVolume: true, // fixtures share the temp volume
            requireNewOutputRoots: resumeManifest == nil && retryManifest == nil && duplicateManifests.isEmpty,
            resumeManifest: resumeManifest,
            retryManifest: retryManifest,
            includedRelativePaths: preflight.includedRelativePaths,
            duplicateManifests: duplicateManifests
        )
    }

    private static func directRequest(
        source: URL,
        into base: URL,
        spool: URL,
        fingerprint: String? = nil
    ) -> TransferRequest {
        TransferRequest(
            sourceRoot: source,
            destinations: [TransferDestination(baseRoot: base, outputRoot: base)],
            algorithm: .xxh3,
            sourceFingerprint: fingerprint,
            spoolDirectory: spool,
            allowSameVolume: true,
            requireNewOutputRoots: true
        )
    }

    /// Port of repro_engineDirectOutputRootEqualToBaseIsNotACollision.
    @Test func engineTreatsADirectOutputAsTheExistingBaseNotANewFolder() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")

        let report = try await Self.run(Self.directRequest(
            source: source, into: base, spool: fixtures.root.appendingPathComponent("spool")))

        #expect(report.status == .verified, "issues: \(report.issues)")
        for spec in Self.directCard {
            #expect(report.outcome(spec.path, at: base) == .verified)
            #expect(try fixtures.bytes(at: base.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(report.manifestLocations.contains(base))
        #expect(!report.issues.contains { $0.contains("already exists") })
    }

    /// Port of repro_directLayoutReviewedPlanStartedLikeTheAppVerifies.
    @Test func directLayoutStartedLikeTheAppVerifiesBesideUnrelatedMaterial() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")
        let unrelated = base.appendingPathComponent("OTHER_SHOOT/notes.txt")
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: unrelated)

        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [base], folderName: "",
            algorithm: .xxh3, layout: .directly)
        #expect(preflight.canStart, "\(preflight.blockingIssues)")
        #expect(preflight.destinations.first?.output.path == base.path)

        let report = try await Self.run(Self.appRequest(
            for: preflight, spool: fixtures.root.appendingPathComponent("spool")))

        #expect(report.status == .verified, "issues: \(report.issues)")
        #expect(report.items.count == Self.directCard.count)
        for spec in Self.directCard {
            #expect(report.outcome(spec.path, at: base) == .verified)
            #expect(try fixtures.bytes(at: base.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(try Data(contentsOf: unrelated) == Data("keep me".utf8))
    }

    /// Control (port of repro_newFolderLayoutReviewedPlanStartedLikeTheAppVerifies):
    /// the same app-shaped request for the default layout.
    @Test func newFolderLayoutStartedLikeTheAppVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")

        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [base], folderName: "20260810_A001",
            algorithm: .xxh3, layout: .newFolder)
        #expect(preflight.canStart, "\(preflight.blockingIssues)")

        let report = try await Self.run(Self.appRequest(
            for: preflight, spool: fixtures.root.appendingPathComponent("spool")))
        let output = base.appendingPathComponent("20260810_A001", isDirectory: true)

        #expect(report.status == .verified, "issues: \(report.issues)")
        #expect(report.outcome("DCIM/100/A001.MOV", at: output) == .verified)
    }

    /// The exemption did not widen: a fresh offload's existing task folder is
    /// still a whole-destination collision, and nothing in it is touched.
    @Test func anExistingTaskFolderStillFailsWholeAsACollision() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")
        let output = base.appendingPathComponent("20260810_A001", isDirectory: true)
        let earlier = output.appendingPathComponent("EARLIER/clip.mov")
        try FileManager.default.createDirectory(
            at: earlier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier task".utf8).write(to: earlier)

        let report = try await Self.run(TransferRequest(
            sourceRoot: source,
            destinations: [TransferDestination(baseRoot: base, outputRoot: output)],
            algorithm: .xxh3,
            spoolDirectory: fixtures.root.appendingPathComponent("spool"),
            allowSameVolume: true,
            requireNewOutputRoots: true
        ))

        #expect(report.status == .failed)
        for spec in Self.directCard {
            #expect(report.outcome(spec.path, at: output) == .failed(.nameCollision))
            #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent(spec.path).path))
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(spec.path).path))
        }
        #expect(try Data(contentsOf: earlier) == Data("earlier task".utf8))
    }

    /// The base comparison is literal: a task folder that merely resolves to
    /// its base (a link named like the folder) is still an existing folder.
    @Test func aTaskFolderThatLinksToItsBaseIsStillACollision() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")
        let output = base.appendingPathComponent("20260810_A001", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: base)

        let report = try await Self.run(TransferRequest(
            sourceRoot: source,
            destinations: [TransferDestination(baseRoot: base, outputRoot: output)],
            algorithm: .xxh3,
            spoolDirectory: fixtures.root.appendingPathComponent("spool"),
            allowSameVolume: true,
            requireNewOutputRoots: true
        ))

        #expect(report.status == .failed)
        for spec in Self.directCard {
            #expect(report.outcome(spec.path, at: output) == .failed(.nameCollision))
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent(spec.path).path))
        }
    }

    /// The per-file guarantee that now carries the direct layout: a file
    /// already at a planned path fails that pair and is never replaced.
    @Test func directOutputFailsACollidingFileAndNeverReplacesIt() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let base = try fixtures.makeDestination(named: "RAID")
        let occupied = base.appendingPathComponent(Self.directCard[0].path)
        try FileManager.default.createDirectory(
            at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("someone else's clip".utf8).write(to: occupied)

        let report = try await Self.run(Self.directRequest(
            source: source, into: base, spool: fixtures.root.appendingPathComponent("spool")))

        #expect(report.status == .failed)
        #expect(report.outcome(Self.directCard[0].path, at: base) == .failed(.nameCollision))
        #expect(report.outcome(Self.directCard[1].path, at: base) == .verified)
        #expect(try Data(contentsOf: occupied) == Data("someone else's clip".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: base.appendingPathComponent(".doppelganger-failed").path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: occupied.deletingLastPathComponent().path
        ).filter { $0.hasPrefix(".doppelganger-partial-") }
        #expect(leftovers.isEmpty)
    }

    /// A batch reviews every source before any of them writes. Two direct
    /// cards sharing a relative path into one base: the second card fails
    /// only the shared name, and the first card's verified bytes stay put.
    @Test func aSecondDirectCardFailsOnlyTheSharedNameAndKeepsTheFirstCardsBytes() async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(named: "CARD_A", files: [
            FixtureBuilder.FileSpec("DCIM/100/C0001.MP4", size: 70_000, seed: 71),
            FixtureBuilder.FileSpec("DCIM/100/C0002.MP4", size: 3_000, seed: 72),
        ])
        let cardB = try fixtures.makeCard(named: "CARD_B", files: [
            FixtureBuilder.FileSpec("DCIM/100/C0001.MP4", size: 70_000, seed: 81),
            FixtureBuilder.FileSpec("DCIM/100/C0003.MP4", size: 3_000, seed: 83),
        ])
        let base = try fixtures.makeDestination(named: "RAID")
        let reviewA = await TransferPreflight.inspect(
            source: cardA, destinationBases: [base], folderName: "", algorithm: .xxh3, layout: .directly)
        let reviewB = await TransferPreflight.inspect(
            source: cardB, destinationBases: [base], folderName: "", algorithm: .xxh3, layout: .directly)
        #expect(reviewA.canStart && reviewB.canStart)

        let reportA = try await Self.run(Self.appRequest(
            for: reviewA, spool: fixtures.root.appendingPathComponent("spool-a")))
        #expect(reportA.status == .verified, "issues: \(reportA.issues)")
        let reportB = try await Self.run(Self.appRequest(
            for: reviewB, spool: fixtures.root.appendingPathComponent("spool-b")))

        #expect(reportB.status == .failed)
        #expect(reportB.outcome("DCIM/100/C0001.MP4", at: base) == .failed(.nameCollision))
        #expect(reportB.outcome("DCIM/100/C0003.MP4", at: base) == .verified)
        #expect(try fixtures.bytes(at: base.appendingPathComponent("DCIM/100/C0001.MP4"))
            == fixtures.bytes(at: cardA.appendingPathComponent("DCIM/100/C0001.MP4")))
    }

    /// Merge gate between the retry quarantine and the enumeration filter.
    /// After the collision above, the operator's next step is Retry Failures
    /// on the second card. Whatever that retry does with the first card's
    /// verified clip (refuses and leaves it in place, or sets it aside under
    /// `.doppelganger-failed`), the clip must stay in the plan a cascade from
    /// this base builds. This fails only if the quarantine tree is hidden
    /// while a retry can still move a file its parent never published.
    @Test func aDirectBatchRetryNeverHidesTheFirstCardsVerifiedClip() async throws {
        let fixtures = try FixtureBuilder()
        let shared = "DCIM/100/C0001.MP4"
        let cardA = try fixtures.makeCard(named: "CARD_A", files: [
            FixtureBuilder.FileSpec(shared, size: 70_000, seed: 71),
            FixtureBuilder.FileSpec("DCIM/100/C0002.MP4", size: 3_000, seed: 72),
        ])
        let cardB = try fixtures.makeCard(named: "CARD_B", files: [
            FixtureBuilder.FileSpec(shared, size: 70_000, seed: 81),
            FixtureBuilder.FileSpec("DCIM/100/C0003.MP4", size: 3_000, seed: 83),
        ])
        let base = try fixtures.makeDestination(named: "RAID")
        let reportA = try await Self.run(Self.directRequest(
            source: cardA, into: base, spool: fixtures.root.appendingPathComponent("spool-a")))
        try #require(reportA.status == .verified, "issues: \(reportA.issues)")
        let reportB = try await Self.run(Self.directRequest(
            source: cardB, into: base, spool: fixtures.root.appendingPathComponent("spool-b")))
        try #require(reportB.outcome(shared, at: base) == .failed(.nameCollision))
        let clipA = try fixtures.bytes(at: cardA.appendingPathComponent(shared))

        // What AppModel.retryFailures and TransferSession.start() build: the
        // parent's failed pairs at its one destination, no fresh-folder rule.
        _ = try await Self.run(TransferRequest(
            sourceRoot: cardB,
            destinations: [TransferDestination(baseRoot: base, outputRoot: base)],
            algorithm: .xxh3,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-b-retry"),
            allowSameVolume: true,
            requireNewOutputRoots: false,
            retryManifest: try EngineHarness.decodeManifest(at: base, shortID: reportB.shortID),
            includedRelativePaths: [shared]
        ))

        let plan = try RealFileSystem().enumerate(root: base)
        let planCarriesClipA = try plan.contains { item in
            guard item.size == Int64(clipA.count) else { return false }
            return try fixtures.bytes(at: base.appendingPathComponent(item.relativePath)) == clipA
        }
        #expect(planCarriesClipA, "card A's verified clip dropped out of \(plan.map(\.relativePath))")
    }

    /// The duplicate-mode clause had the same bug: once any destination has a
    /// prior verified candidate, a direct destination without one must not be
    /// vetoed as an existing output folder.
    @Test func directDestinationWithoutADuplicateCandidateIsNotVetoedInDuplicateMode() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.directCard)
        let raidA = try fixtures.makeDestination(named: "RAID-A")
        let raidB = try fixtures.makeDestination(named: "RAID-B")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))

        let first = try await Self.run(Self.directRequest(
            source: source, into: raidA,
            spool: fixtures.root.appendingPathComponent("spool-1"), fingerprint: fingerprint))
        #expect(first.status == .verified, "issues: \(first.issues)")
        let manifest = try EngineHarness.decodeManifest(at: raidA, shortID: first.shortID)

        let second = try await Self.run(TransferRequest(
            sourceRoot: source,
            destinations: [raidA, raidB].map { TransferDestination(baseRoot: $0, outputRoot: $0) },
            algorithm: .xxh3,
            sourceFingerprint: fingerprint,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-2"),
            allowSameVolume: true,
            requireNewOutputRoots: false, // what TransferSession.start computes once duplicates exist
            duplicateManifests: [raidA.path: manifest]
        ))

        #expect(second.status == .verified, "issues: \(second.issues)")
        for spec in Self.directCard {
            #expect(second.outcome(spec.path, at: raidA) == .verifiedDuplicate)
            #expect(second.outcome(spec.path, at: raidB) == .verified)
            #expect(try fixtures.bytes(at: raidB.appendingPathComponent(spec.path)) == spec.bytes)
        }
    }
}
