import Foundation
import Testing
@testable import Doppelganger

/// The linked attempt, if any, a paused run's journal sits beside at quit.
enum LinkedChildShape: CaseIterable, Sendable {
    case none, neverStarted, stoppedBeforeDestinations, reachedDestinations, interruptedMidRun, parentRecordMissing
}

/// Review follow-up to L2/L3 (lifecycle-safety-correctness-1,
/// lifecycle-regressions-scope-merge-1): a resume or repair the engine stops
/// before it reaches any destination never takes its parent's destinations
/// over. The parent keeps its Resume or Retry for the rest of the launch,
/// comes back after relaunch, and the quit warning agrees with the launch.
///
/// Every run writes into a FixtureBuilder temp directory; every AppModel
/// recovers from the fixture's own spool over an in-memory catalog. No test
/// builds a non-recovered TransferSession or calls AppModel.resume on a path
/// that could start one: both write a journal into the host's spool. The
/// in-session release is pinned on `AttemptContinuations.settle`, the one
/// call AppModel's finish callback makes.
@MainActor
struct LinkedAttemptReleaseTests {
    private typealias World = PausedAttemptRestoreTests.World

    /// The journal TransferSession keeps for a linked attempt of the world's
    /// paused run, before its verdict is recorded.
    private static func childJournal(
        of world: World,
        id: UUID = UUID(),
        kind: TransferAttemptKind = .resume,
        startedAt: Date? = Date(),
        status: TransferJournal.Status = .running
    ) -> TransferJournal {
        TransferJournal(
            id: id,
            taskID: world.run.report.taskID,
            parentAttemptID: world.run.report.id,
            attemptKind: kind,
            label: world.journal.label,
            source: world.source,
            destinationBases: [world.destination],
            destinations: [world.destination],
            algorithm: .xxh64,
            verificationProfile: .standard,
            sourceFingerprint: world.journal.sourceFingerprint,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: startedAt,
            itemCount: 0,
            totalBytes: 0,
            status: status
        )
    }

    /// What AppModel.resume forwards for the world's paused card.
    private static func resumeRequest(
        _ world: World,
        model: AppModel
    ) throws -> (card: TransferSession, manifest: TransferManifest, scope: ResumeScope) {
        let card = try #require(model.sessions.first { $0.id == world.run.report.id })
        let manifest = try model.resumeManifest(for: card)
        let scope = try #require(AppModel.resumeScope(
            pausedScope: card.includedRelativePaths,
            pausedFingerprint: card.sourceFingerprint,
            manifest: manifest
        ))
        return (card, manifest, scope)
    }

    private static func resume(
        _ world: World,
        manifest: TransferManifest,
        scope: ResumeScope,
        spool: String
    ) async throws -> EngineHarness.Run {
        try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent(spool, isDirectory: true),
            sourceFingerprint: scope.sourceFingerprint,
            resumeManifest: manifest,
            includedRelativePaths: scope.includedRelativePaths
        )
    }

    // MARK: - Same launch

    /// The finding's scenario: another card with the same volume name sits at
    /// the paused card's path. Resume passes its own checks, the engine
    /// refuses the plan, and nothing reaches the destination. The parent's
    /// Resume comes back, and once the right card is in, the same pause
    /// resumes to Verified.
    @Test func aResumeRefusedOnASameNamedCardHandsResumeBack() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try PausedAttemptRestoreTests.relaunch(world)
        let request = try Self.resumeRequest(world, model: model)
        let destinationBefore = try world.fixtures.digestSnapshot(of: world.destination)

        let parked = world.fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: world.source, to: parked)
        _ = try world.fixtures.makeCard(
            named: world.source.lastPathComponent,
            files: [.init("DCIM/100CANON/IMG_0001.CR3", size: 90_000, seed: 9)]
        )
        _ = try model.resumeManifest(for: request.card)

        let refused = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "refused-spool")

        #expect(refused.report.status == .failed)
        #expect(refused.report.issues.contains("The source plan changed after review; run preflight again."))
        #expect(refused.report.neverReachedDestinations)
        #expect(try world.fixtures.digestSnapshot(of: world.destination) == destinationBefore)
        var continuations = AttemptContinuations()
        continuations.claim([world.destination], of: request.card.id, by: refused.report.id)
        try #require(continuations.availability(of: request.card.id) != .open)
        continuations.settle(child: refused.report.id, with: refused.report)
        #expect(continuations.availability(of: request.card.id) == .open)

        // The operator puts the right card back and presses Resume again.
        try FileManager.default.removeItem(at: world.source)
        try FileManager.default.moveItem(at: parked, to: world.source)
        _ = try model.resumeManifest(for: request.card)
        let resumed = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "resume-spool")
        #expect(resumed.report.status == .verified)
        for spec in EngineHarness.standardFiles {
            #expect(try world.fixtures.bytes(at: world.destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
    }

    /// The card was pulled while the resume waited in the queue. The engine
    /// cannot read the source, writes only its own failed record beside the
    /// parent's, and touches no media; the pause still resumes afterwards.
    @Test func aResumeWhoseCardWasPulledHandsResumeBack() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try PausedAttemptRestoreTests.relaunch(world)
        let request = try Self.resumeRequest(world, model: model)
        let destinationBefore = try world.fixtures.digestSnapshot(of: world.destination)
        let parked = world.fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: world.source, to: parked)

        let refused = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "refused-spool")

        #expect(refused.report.status == .failed)
        #expect(refused.report.neverReachedDestinations)
        let after = try world.fixtures.digestSnapshot(of: world.destination)
        #expect(after.filter { !$0.key.contains(refused.report.shortID) } == destinationBefore)
        var continuations = AttemptContinuations()
        continuations.claim([world.destination], of: request.card.id, by: refused.report.id)
        continuations.settle(child: refused.report.id, with: refused.report)
        #expect(continuations.availability(of: request.card.id) == .open)

        try FileManager.default.moveItem(at: parked, to: world.source)
        _ = try model.resumeManifest(for: request.card)
        let resumed = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "resume-spool")
        #expect(resumed.report.status == .verified)
    }

    /// A resume that ran keeps its claim, whatever its verdict.
    @Test func aResumeThatReachedItsDestinationKeepsTheParentClosed() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try PausedAttemptRestoreTests.relaunch(world)
        let request = try Self.resumeRequest(world, model: model)

        let resumed = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "resume-spool")
        try #require(resumed.report.status == .verified)

        #expect(!resumed.report.neverReachedDestinations)
        var continuations = AttemptContinuations()
        continuations.claim([world.destination], of: request.card.id, by: resumed.report.id)
        continuations.settle(child: resumed.report.id, with: resumed.report)
        #expect(continuations.availability(of: request.card.id) == .continued([world.destination]))
    }

    /// The subtle case behind "no outcome at all": a run cancelled after it
    /// published copies records the pairs it never verified as skipped, yet
    /// those files are on the destination. It reached it, so it never hands
    /// its parent back.
    @Test func aRunCancelledAfterPublishingCopiesStillReachedItsDestination() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "cancelled-destination")
        // Slow read-back so the cancel lands before verification finishes.
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        let run = try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"),
            chunkSize: 4 * 1024,
            cancelWhen: { event in
                if case .phaseChanged(.verifying) = event { return true }
                return false
            }
        )
        try #require(run.report.status == .cancelled)
        let published = run.report.items.filter {
            FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.item.relativePath).path)
        }
        try #require(!published.isEmpty)

        #expect(!run.report.neverReachedDestinations)
        var continuations = AttemptContinuations()
        let parent = UUID()
        continuations.claim([destination], of: parent, by: run.report.id)
        continuations.settle(child: run.report.id, with: run.report)
        #expect(continuations.availability(of: parent) == .continued([destination]))
    }

    /// The repair half: a repair stopped before its destination hands the
    /// failed card's Retry back for that destination.
    @Test func aRepairStoppedBeforeItsDestinationHandsRetryBack() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "repair-destination")
        let faulty = FailpointFileSystem(base: RealFileSystem())
        faulty.corruptFirstByteOnWrite(pathSuffix: "repair-destination/DCIM/100MEDIA/a.bin")
        let failed = try await EngineHarness.run(
            fileSystem: faulty,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("failed-spool")
        )
        try #require(failed.report.status == .failed)
        let parentManifest = try EngineHarness.decodeManifest(at: destination, shortID: failed.report.shortID)
        let failedPaths = AppModel.failedRelativePaths(in: failed.report, at: destination)
        try #require(failedPaths == ["DCIM/100MEDIA/a.bin"])
        let parked = fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: parked)

        let repair = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("repair-spool"),
            retryManifest: parentManifest,
            includedRelativePaths: failedPaths
        )

        #expect(repair.report.status == .failed)
        #expect(repair.report.neverReachedDestinations)
        var continuations = AttemptContinuations()
        continuations.claim([destination], of: failed.report.id, by: repair.report.id)
        #expect(AppModel.retryableFailedPairCount(
            in: failed.report, destinations: [destination],
            availability: continuations.availability(of: failed.report.id)
        ) == 0)
        continuations.settle(child: repair.report.id, with: repair.report)
        #expect(AppModel.retryableFailedPairCount(
            in: failed.report, destinations: [destination],
            availability: continuations.availability(of: failed.report.id)
        ) == 1)
    }

    /// The journal keeps exactly what the report says, so a later launch
    /// applies the same rule.
    @Test func theJournalRecordsWhetherTheEngineReachedADestination() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        #expect(world.journal.neverReachedDestinations == nil)

        let manifest = try ManifestWriter.decode(Data(contentsOf: world.spoolManifest))
        let scope = try #require(AppModel.resumeScope(
            pausedScope: nil, pausedFingerprint: world.journal.sourceFingerprint, manifest: manifest
        ))
        let parked = world.fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: world.source, to: parked)
        let refused = try await Self.resume(world, manifest: manifest, scope: scope, spool: "refused-spool")
        var refusedJournal = Self.childJournal(of: world, id: refused.report.id)
        refusedJournal.recordVerdict(of: refused.report)
        #expect(refusedJournal.status == .failed)
        #expect(refusedJournal.neverReachedDestinations == true)
        #expect(refusedJournal.offeredAtLaunch == nil)

        try FileManager.default.moveItem(at: parked, to: world.source)
        let resumed = try await Self.resume(world, manifest: manifest, scope: scope, spool: "resume-spool")
        var resumedJournal = Self.childJournal(of: world, id: resumed.report.id)
        resumedJournal.recordVerdict(of: resumed.report)
        #expect(resumedJournal.status == .verified)
        #expect(resumedJournal.neverReachedDestinations == nil)

        // Only a stop before any destination writes the key; every other
        // journal, like every one written before it existed, has none.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode(resumedJournal)
        #expect(!String(decoding: legacy, as: UTF8.self).contains("neverReachedDestinations"))
    }

    // MARK: - Next launch

    /// The finding's relaunch half: the refused resume's journal shows it
    /// started, yet the pause comes back with its Resume, the refused child
    /// is not offered, and quitting again costs nothing.
    @Test func aPauseWhoseResumeWasRefusedComesBackAfterRelaunch() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let request = try Self.resumeRequest(world, model: try PausedAttemptRestoreTests.relaunch(world))
        let parked = world.fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: world.source, to: parked)
        let refused = try await Self.resume(world, manifest: request.manifest, scope: request.scope, spool: "spool")
        var child = Self.childJournal(of: world, id: refused.report.id)
        child.recordVerdict(of: refused.report)
        TransferJournalStore(root: world.spool).save(child)
        try FileManager.default.moveItem(at: parked, to: world.source)

        let model = try PausedAttemptRestoreTests.relaunch(world)

        #expect(model.sessions.map(\.id) == [world.run.report.id])
        let card = try #require(model.sessions.first)
        #expect(card.report?.status == .paused)
        #expect(model.continuation(of: card.id) == .open)
        _ = try model.resumeManifest(for: card)
        #expect(model.quitImpact == QuitImpact())
    }

    /// The quit warning and the next launch apply one rule: an attempt is
    /// offered again exactly when its fate says so, and carried on exactly
    /// when a linked attempt took its destinations over.
    @Test(arguments: LinkedChildShape.allCases)
    func theQuitWarningAndTheNextLaunchAgree(_ shape: LinkedChildShape) async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let parentID = world.run.report.id
        let store = TransferJournalStore(root: world.spool)
        let expected: LaunchFate
        switch shape {
        case .none:
            expected = .offered
        case .neverStarted:
            store.save(Self.childJournal(of: world, startedAt: nil, status: .queued))
            expected = .offered
        case .stoppedBeforeDestinations:
            var child = Self.childJournal(of: world)
            child.recordVerdict(.failed)
            child.neverReachedDestinations = true
            store.save(child)
            expected = .offered
        case .reachedDestinations:
            var child = Self.childJournal(of: world)
            child.recordVerdict(.failed)
            store.save(child)
            expected = .continued
        case .interruptedMidRun:
            store.save(Self.childJournal(of: world, status: .interrupted))
            expected = .continued
        case .parentRecordMissing:
            try FileManager.default.removeItem(at: world.spoolManifest)
            expected = .lost
        }

        #expect(store.launchFates(of: [parentID]) == [parentID: expected])
        let offers = store.launchOffers()
        let restorable = offers.contains {
            if case .restorable(let attempt) = $0 { return attempt.journal.id == parentID }
            return false
        }
        let listed = offers.contains {
            switch $0 {
            case .restorable(let attempt): attempt.journal.id == parentID
            case .unreadable(let journal): journal.id == parentID
            }
        }
        #expect(restorable == (expected == .offered))
        #expect(listed == (expected != .continued))

        let model = try PausedAttemptRestoreTests.relaunch(world)
        let card = model.sessions.first { $0.id == parentID }
        #expect((card != nil) == (expected != .continued))
        #expect((card?.report?.status == .paused) == (expected == .offered))
        #expect(model.continuation(of: parentID) == (expected == .continued ? .continued([world.destination]) : .open))
        // A never-started child gets no card of its own.
        #expect(model.sessions.allSatisfy { $0.id == parentID })
    }

    /// A paused card on the dashboard whose resume took it over is that
    /// resume's to report: quitting never calls it lost. One whose resume was
    /// stopped before any destination is offered again, so it costs nothing
    /// either, until its own record is gone.
    @Test func aPauseCarriedOnByItsResumeNeverWarnsAtQuit() async throws {
        let world = try await PausedAttemptRestoreTests.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try PausedAttemptRestoreTests.relaunch(world)
        try #require(model.sessions.map(\.id) == [world.run.report.id])
        let store = TransferJournalStore(root: world.spool)

        var child = Self.childJournal(of: world)
        child.recordVerdict(.verified)
        store.save(child)
        #expect(store.launchFates(of: [world.run.report.id]) == [world.run.report.id: .continued])
        #expect(model.quitImpact == QuitImpact())

        child.recordVerdict(.failed)
        child.neverReachedDestinations = true
        store.save(child)
        #expect(store.launchFates(of: [world.run.report.id]) == [world.run.report.id: .offered])
        #expect(model.quitImpact == QuitImpact())

        // Its own record gone: lost only while no linked attempt carries it on.
        try FileManager.default.removeItem(at: world.spoolManifest)
        #expect(model.quitImpact == QuitImpact(unrecoverable: 1))
        child.recordVerdict(.verified)
        child.neverReachedDestinations = nil
        store.save(child)
        #expect(model.quitImpact == QuitImpact())
    }
}
