import Foundation
import Testing
@testable import Doppelganger

/// L1: the catalog closes what the app itself ended without an engine
/// `.finished` event (findings platform-io-db-5, app-orchestration-7,
/// app-services-1), and the launch spool import never re-catalogs the app's
/// own manifests (platform-io-db-6). Ports Repro_G10_catalog_finalize.
///
/// In-memory catalogs only; spools and journals live in FixtureBuilder temp
/// directories. No TransferSession is built that saves a journal:
/// `TransferSession(interrupted:)` never saves one.
private enum CatalogFixture {
    static let launch = Date(timeIntervalSince1970: 1_786_100_000)
    static let earlier = launch.addingTimeInterval(-3_600)
    static let failure = ItemDestinationOutcome.failed(
        .checksumMismatch(expected: "0123456789abcdef", actual: "1111111111111111")
    )
    /// Every terminal status, with the profile and per-pair outcome a real run
    /// of that status records.
    static let terminalCases: [(TransferStatus, VerificationProfile, ItemDestinationOutcome)] = [
        (.verified, .standard, .verified),
        (.transferredPendingVerification, .fast, .transferredPendingVerification),
        (.paused, .standard, .skipped(.paused)),
        (.failed, .standard, failure),
        (.cancelled, .standard, .skipped(.cancelled)),
    ]

    @discardableResult
    static func queuedTask(
        in database: ProductDatabase,
        id: UUID = UUID(),
        destinations: [URL] = [ReportFixtures.destinationA],
        at date: Date = earlier,
        profile: VerificationProfile = .standard
    ) throws -> UUID {
        try database.registerTask(
            id: id, label: "20260810_A001", source: ReportFixtures.source,
            destinations: destinations, projectID: nil,
            operatorProfile: database.activeProfile(),
            algorithm: .xxh64, verificationProfile: profile, createdAt: date
        )
        return id
    }

    /// A copy task whose first attempt started (as `onStarted` records it).
    @discardableResult
    static func startedCopy(
        in database: ProductDatabase,
        destinations: [URL] = [ReportFixtures.destinationA],
        at date: Date = earlier,
        profile: VerificationProfile = .standard
    ) throws -> UUID {
        let id = try queuedTask(in: database, destinations: destinations, at: date, profile: profile)
        try database.registerAttempt(
            id: id, taskID: id, kind: .copy, operatorProfile: database.activeProfile(),
            algorithm: .xxh64, verificationProfile: profile, startedAt: date
        )
        return id
    }

    static func report(
        id: UUID,
        taskID: UUID? = nil,
        status: TransferStatus,
        profile: VerificationProfile = .standard,
        outcome: ItemDestinationOutcome,
        manifestLocations: [URL] = []
    ) -> TransferReport {
        TransferReport(
            id: id, status: status, algorithm: .xxh64, verificationProfile: profile,
            taskID: taskID ?? id, sourceRoot: ReportFixtures.source,
            destinations: [ReportFixtures.destinationA],
            startedAt: earlier, finishedAt: earlier.addingTimeInterval(30),
            items: [ItemResult(
                item: SourceItem(relativePath: "DCIM/100MEDIA/A001.MP4", size: 1_234_567),
                sourceDigest: "0123456789abcdef",
                outcomes: [ReportFixtures.destinationA: outcome]
            )],
            manifestLocations: manifestLocations
        )
    }

    /// Writes the spool manifest the engine leaves for a run, and returns the
    /// report whose manifestLocations include that spool folder.
    static func spoolManifest(
        id: UUID, status: TransferStatus, profile: VerificationProfile,
        outcome: ItemDestinationOutcome, spool: URL
    ) throws -> TransferReport {
        let shortID = String(id.uuidString.prefix(8)).lowercased()
        let target = spool.appendingPathComponent(shortID, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let report = report(id: id, status: status, profile: profile, outcome: outcome,
                            manifestLocations: [target])
        try ManifestWriter.jsonData(for: TransferManifest(report: report)).write(
            to: target.appendingPathComponent(ManifestWriter.manifestFileName(shortID: shortID)),
            options: .withoutOverwriting
        )
        return report
    }

    struct Snapshot: Equatable {
        let tasks: [TaskHistoryRecord]
        let attempts: [AttemptHistoryRecord]
        let evidence: [EvidenceArtifactHistoryRecord]
        let audit: Set<AuditEventRecord>
    }

    static func snapshot(_ database: ProductDatabase) throws -> Snapshot {
        let tasks = try database.taskHistory()
        return try Snapshot(
            tasks: tasks,
            attempts: tasks.flatMap { try database.attemptHistory(taskID: $0.id) },
            evidence: tasks.flatMap { try database.evidenceArtifacts(taskID: $0.id) },
            audit: Set(database.auditEvents())
        )
    }

    static func systemActions(_ database: ProductDatabase, task: UUID) throws -> [AuditAction] {
        try database.auditEvents(taskID: task).filter { $0.actorKind == .system }.map(\.action)
    }
}

struct CatalogFinalizationTests {
    @Test func anOpenAttemptIsClosedAsFailedAtLaunch() throws {
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.startedCopy(in: database)

        let closed = try database.closeAbandonedRuns(
            before: CatalogFixture.launch, closedAt: CatalogFixture.launch
        )

        #expect(closed.failedAttemptIDs == [id])
        #expect(closed.cancelledTaskIDs.isEmpty)
        let attempt = try #require(database.attemptHistory(taskID: id).first)
        #expect(attempt.verdict == .failed)
        #expect(attempt.lifecycle == .failed)
        #expect(attempt.finishedAt == CatalogFixture.launch)
        #expect(attempt.issues == [ProductDatabase.abandonedAttemptIssue])
        #expect(attempt.fileCount == 0)
        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .failed)
        #expect(task.lifecycle == .failed)
        let system = try database.auditEvents(taskID: id).filter { $0.actorKind == .system }
        #expect(system.map(\.action) == [.attemptFailed])
        #expect(system.first?.attemptID == id)
        #expect(system.first?.detail == ProductDatabase.abandonedAttemptIssue)
    }

    @Test func anAbandonedAttemptIsCreditedWithNoEvidence() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "raid")
        // A chain the abandoned run may or may not have committed.
        let chainFolder = destination.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: chainFolder, withIntermediateDirectories: true)
        try Data("<ascmhldirectory/>".utf8).write(to: chainFolder.appendingPathComponent(MHLWriter.chainFileName))
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.startedCopy(in: database, destinations: [destination])

        try database.closeAbandonedRuns(before: CatalogFixture.launch, closedAt: CatalogFixture.launch)

        #expect(try database.evidenceArtifacts(taskID: id).isEmpty)
        #expect(try database.attemptHistory(taskID: id).first?.verdict == .failed)
    }

    @Test func aQueuedTaskThatNeverStartedIsCancelledAtLaunch() throws {
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.queuedTask(in: database)

        let closed = try database.closeAbandonedRuns(
            before: CatalogFixture.launch, closedAt: CatalogFixture.launch
        )

        #expect(closed.cancelledTaskIDs == [id])
        #expect(closed.failedAttemptIDs.isEmpty)
        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .cancelled)
        #expect(task.lifecycle == .cancelled)
        #expect(try database.attemptHistory(taskID: id).isEmpty)
        let system = try database.auditEvents(taskID: id).filter { $0.actorKind == .system }
        #expect(system.map(\.action) == [.taskCancelled])
        #expect(system.first?.detail == ProductDatabase.neverStartedTaskDetail)
    }

    @Test func launchClosureIsIdempotentAndNeverRewritesAFinishedAttempt() throws {
        let database = try ProductDatabase(inMemory: true)
        let verified = try CatalogFixture.startedCopy(in: database)
        try database.finishAttempt(
            id: verified, taskID: verified,
            report: CatalogFixture.report(id: verified, status: .verified, outcome: .verified),
            verificationProfile: .standard
        )
        let open = try CatalogFixture.startedCopy(in: database)

        let first = try database.closeAbandonedRuns(
            before: CatalogFixture.launch, closedAt: CatalogFixture.launch
        )
        #expect(first.failedAttemptIDs == [open])
        let afterFirst = try CatalogFixture.snapshot(database)

        let second = try database.closeAbandonedRuns(
            before: CatalogFixture.launch.addingTimeInterval(60),
            closedAt: CatalogFixture.launch.addingTimeInterval(60)
        )

        #expect(second == ProductDatabase.AbandonedRuns())
        #expect(try CatalogFixture.snapshot(database) == afterFirst)
        let task = try #require(database.taskHistory().first { $0.id == verified })
        #expect(task.verdict == .verified)
        #expect(try database.attemptHistory(taskID: verified).first?.verdict == .verified)
    }

    @Test func rowsRegisteredAfterTheLaunchInstantAreLeftAlone() throws {
        let database = try ProductDatabase(inMemory: true)
        let later = CatalogFixture.launch.addingTimeInterval(5)
        let started = try CatalogFixture.startedCopy(in: database, at: later)
        let queued = try CatalogFixture.queuedTask(in: database, at: later)

        let closed = try database.closeAbandonedRuns(
            before: CatalogFixture.launch, closedAt: CatalogFixture.launch
        )

        #expect(closed == ProductDatabase.AbandonedRuns())
        let tasks = try database.taskHistory()
        #expect(tasks.first { $0.id == started }?.verdict == .pending)
        #expect(tasks.first { $0.id == queued }?.verdict == .pending)
        #expect(tasks.first { $0.id == queued }?.lifecycle == .queued)
        #expect(try database.attemptHistory(taskID: started).first?.finishedAt == nil)
    }

    @Test func anAbandonedResumeFailsThePausedTaskAndLeavesThePausedAttempt() throws {
        let database = try ProductDatabase(inMemory: true)
        let task = try CatalogFixture.startedCopy(in: database)
        try database.finishAttempt(
            id: task, taskID: task,
            report: CatalogFixture.report(id: task, status: .paused, outcome: .skipped(.paused)),
            verificationProfile: .standard
        )
        let resume = UUID()
        try database.registerAttempt(
            id: resume, taskID: task, parentAttemptID: task, kind: .resume,
            operatorProfile: database.activeProfile(), algorithm: .xxh64,
            verificationProfile: .standard, startedAt: CatalogFixture.earlier.addingTimeInterval(60)
        )

        let closed = try database.closeAbandonedRuns(
            before: CatalogFixture.launch, closedAt: CatalogFixture.launch
        )

        #expect(closed.failedAttemptIDs == [resume])
        let attempts = try database.attemptHistory(taskID: task)
        #expect(attempts.first { $0.id == task }?.verdict == .paused)
        #expect(attempts.first { $0.id == task }?.lifecycle == .paused)
        #expect(attempts.first { $0.id == resume }?.verdict == .failed)
        #expect(try database.taskHistory().first { $0.id == task }?.verdict == .failed)
    }

    @Test func anAbandonedStandaloneVerificationFailsItsOwnTask() throws {
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.queuedTask(in: database)
        // As AppModel.verifyExisting registers it.
        try database.registerAttempt(
            id: id, taskID: id, kind: .verification, operatorProfile: database.activeProfile(),
            algorithm: .xxh64, verificationProfile: .standard, startedAt: CatalogFixture.earlier
        )

        try database.closeAbandonedRuns(before: CatalogFixture.launch, closedAt: CatalogFixture.launch)

        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .failed)
        #expect(task.lifecycle == .failed)
    }

    @Test func withdrawingAQueuedTaskCancelsItAndCreditsTheOperator() throws {
        let database = try ProductDatabase(inMemory: true)
        let profile = try database.activeProfile()
        let id = try CatalogFixture.queuedTask(in: database)

        #expect(try database.withdrawQueuedTask(id: id, operatorProfile: profile, at: CatalogFixture.launch))

        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .cancelled)
        #expect(task.lifecycle == .cancelled)
        let cancelled = try database.auditEvents(taskID: id).filter { $0.action == .taskCancelled }
        #expect(cancelled.count == 1)
        #expect(cancelled.first?.actorKind == .operatorProfile)
        #expect(cancelled.first?.operatorSnapshot == OperatorSnapshot(profile: profile))
        #expect(cancelled.first?.detail == ProductDatabase.withdrawnTaskDetail)

        #expect(try !database.withdrawQueuedTask(id: id, operatorProfile: profile))
        #expect(try database.closeAbandonedRuns(
            before: CatalogFixture.launch.addingTimeInterval(60)
        ) == ProductDatabase.AbandonedRuns())
        #expect(try database.auditEvents(taskID: id).filter { $0.action == .taskCancelled }.count == 1)
    }

    /// A queued resume or retry shares its parent's task, which has attempts.
    @Test func withdrawingNeverTouchesATaskThatAlreadyHasAttempts() throws {
        let database = try ProductDatabase(inMemory: true)
        let task = try CatalogFixture.startedCopy(in: database)
        try database.finishAttempt(
            id: task, taskID: task,
            report: CatalogFixture.report(id: task, status: .failed, outcome: CatalogFixture.failure),
            verificationProfile: .standard
        )
        let before = try CatalogFixture.snapshot(database)

        #expect(try !database.withdrawQueuedTask(id: task, operatorProfile: database.activeProfile()))
        #expect(try CatalogFixture.snapshot(database) == before)
    }

    /// Replaces the repro's Fast, paused, and verified cases and adds failed
    /// and cancelled: relaunch never appends a second terminal event.
    @Test func relaunchImportAddsNothingForAttemptsTheCatalogAlreadyFinished() throws {
        for (status, profile, outcome) in CatalogFixture.terminalCases {
            let fixtures = try FixtureBuilder()
            let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
            let database = try ProductDatabase(inMemory: true)
            let id = try CatalogFixture.startedCopy(in: database, profile: profile)
            let report = try CatalogFixture.spoolManifest(
                id: id, status: status, profile: profile, outcome: outcome, spool: spool
            )
            try database.finishAttempt(id: id, taskID: id, report: report, verificationProfile: profile)
            let before = try CatalogFixture.snapshot(database)

            try database.importSpoolManifests(at: spool, fallbackProfile: database.activeProfile())
            try database.importSpoolManifests(at: spool, fallbackProfile: database.activeProfile())

            #expect(try CatalogFixture.snapshot(database) == before, "\(status)")
            #expect(try CatalogFixture.systemActions(database, task: id).count == 1, "\(status)")
        }
    }

    @Test func importNeverClosesAnOpenAttemptFromAManifestItMayNotOwn() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.startedCopy(in: database)
        // A VERIFIED record the run left behind before the app died.
        _ = try CatalogFixture.spoolManifest(
            id: id, status: .verified, profile: .standard, outcome: .verified, spool: spool
        )

        try database.importSpoolManifests(at: spool, fallbackProfile: database.activeProfile())

        let attempt = try #require(database.attemptHistory(taskID: id).first)
        #expect(attempt.verdict == .pending)
        #expect(attempt.finishedAt == nil)
        #expect(attempt.fileCount == 0)
        #expect(try database.evidenceArtifacts(taskID: id).isEmpty)
        #expect(try database.auditEvents(taskID: id).allSatisfy { $0.actorKind == .operatorProfile })

        try database.closeAbandonedRuns(before: CatalogFixture.launch, closedAt: CatalogFixture.launch)

        #expect(try database.attemptHistory(taskID: id).first?.verdict == .failed)
        #expect(try database.taskHistory().first { $0.id == id }?.verdict == .failed)
        // The next launch's import only remembers the file.
        let closed = try CatalogFixture.snapshot(database)
        try database.importSpoolManifests(at: spool, fallbackProfile: database.activeProfile())
        #expect(try CatalogFixture.snapshot(database) == closed)
    }

    @Test func legacyImportClosesWithTheSameEventFinishAttemptWould() throws {
        for (status, profile, outcome) in CatalogFixture.terminalCases {
            let finished = try ProductDatabase(inMemory: true)
            let finishedID = try CatalogFixture.startedCopy(in: finished, profile: profile)
            try finished.finishAttempt(
                id: finishedID, taskID: finishedID,
                report: CatalogFixture.report(id: finishedID, status: status, profile: profile, outcome: outcome),
                verificationProfile: profile
            )
            let expected = try CatalogFixture.systemActions(finished, task: finishedID)

            let fixtures = try FixtureBuilder()
            let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
            let legacy = try ProductDatabase(inMemory: true)
            let legacyID = UUID()
            _ = try CatalogFixture.spoolManifest(
                id: legacyID, status: status, profile: profile, outcome: outcome, spool: spool
            )
            try legacy.importSpoolManifests(at: spool, fallbackProfile: legacy.activeProfile())

            #expect(try CatalogFixture.systemActions(legacy, task: legacyID) == expected, "\(status)")
            #expect(expected.count == 1, "\(status)")
        }
    }
}

/// The same rules at launch, driven through `AppModel.init` over an injected
/// spool and catalog, exactly as the app relaunches.
@MainActor
struct CatalogLaunchTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    private static func relaunch(
        database: ProductDatabase,
        fixtures: FixtureBuilder,
        spool: URL
    ) -> AppModel {
        let suiteName = "CatalogLaunch-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return AppModel(
            selectionStore: MemorySelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
            productStore: ProductStore(
                database: database,
                avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: spool
        )
    }

    private static func journal(
        id: UUID,
        fixtures: FixtureBuilder,
        startedAt: Date?,
        status: TransferJournal.Status
    ) -> TransferJournal {
        TransferJournal(
            id: id,
            taskID: id,
            attemptKind: .copy,
            label: "20260810_A001",
            source: fixtures.root.appendingPathComponent("A001", isDirectory: true),
            destinationBases: [fixtures.root.appendingPathComponent("raid", isDirectory: true)],
            destinations: [fixtures.root.appendingPathComponent("raid/20260810_A001", isDirectory: true)],
            algorithm: .xxh64,
            verificationProfile: .standard,
            allowSameVolume: true,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000),
            startedAt: startedAt,
            itemCount: 3,
            totalBytes: 4096,
            status: status
        )
    }

    private static func register(
        _ journal: TransferJournal,
        in database: ProductDatabase,
        started: Bool
    ) throws {
        let operatorProfile = try database.activeProfile()
        try database.registerTask(
            id: journal.id,
            label: journal.label,
            source: journal.source,
            destinations: journal.destinations,
            projectID: nil,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        if started {
            try database.registerAttempt(
                id: journal.id,
                taskID: journal.id,
                kind: .copy,
                operatorProfile: operatorProfile,
                algorithm: .xxh64,
                verificationProfile: .standard
            )
        }
    }

    /// Port of repro_interruptedAttemptIsFinalizedInCatalogOnRecovery,
    /// tightened to the exact verdict and a second relaunch.
    @Test func relaunchClosesTheInterruptedAttemptTheCardShowsAsFailed() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = UUID()
        let interrupted = Self.journal(id: id, fixtures: fixtures, startedAt: Date(), status: .running)
        try Self.register(interrupted, in: database, started: true)
        TransferJournalStore(root: spool).save(interrupted)

        let model = Self.relaunch(database: database, fixtures: fixtures, spool: spool)

        let card = try #require(model.sessions.first { $0.id == id })
        #expect(card.report?.status == .failed)
        #expect(card.isRecovered)
        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .failed)
        #expect(task.lifecycle == .failed)
        let attempt = try #require(database.attemptHistory(taskID: id).first { $0.id == id })
        #expect(attempt.verdict == .failed)
        #expect(attempt.lifecycle == .failed)
        #expect(attempt.finishedAt != nil)
        #expect(attempt.issues == [ProductDatabase.abandonedAttemptIssue])
        #expect(try CatalogFixture.systemActions(database, task: id) == [.attemptFailed])

        let afterFirst = try CatalogFixture.snapshot(database)
        let again = Self.relaunch(database: database, fixtures: fixtures, spool: spool)
        #expect(again.sessions.isEmpty)
        #expect(try CatalogFixture.snapshot(database) == afterFirst)
        #expect(try CatalogFixture.systemActions(database, task: id) == [.attemptFailed])
    }

    /// Port of repro_neverStartedQueuedTaskIsNotLeftPendingAfterRelaunch,
    /// tightened from the repro's lenient `if let`.
    @Test func relaunchCancelsATaskThatNeverStarted() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = UUID()
        let queued = Self.journal(id: id, fixtures: fixtures, startedAt: nil, status: .queued)
        try Self.register(queued, in: database, started: false)
        TransferJournalStore(root: spool).save(queued)

        _ = Self.relaunch(database: database, fixtures: fixtures, spool: spool)

        let task = try #require(database.taskHistory().first { $0.id == id })
        #expect(task.verdict == .cancelled)
        #expect(task.lifecycle == .cancelled)
        #expect(try CatalogFixture.systemActions(database, task: id) == [.taskCancelled])
    }

    /// Closure is catalog-driven, so it holds however journals are recovered.
    @Test func relaunchCancelsANeverStartedTaskEvenWithoutARecoveredJournal() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = UUID()
        try Self.register(
            Self.journal(id: id, fixtures: fixtures, startedAt: nil, status: .queued),
            in: database,
            started: false
        )

        let model = Self.relaunch(database: database, fixtures: fixtures, spool: spool)

        #expect(model.sessions.isEmpty)
        #expect(try database.taskHistory().first { $0.id == id }?.verdict == .cancelled)
    }

    /// Historical phantom rows: a launch before this fix already turned the
    /// journal `.interrupted`, so no card comes back, but the catalog closes.
    @Test func relaunchClosesAnAttemptWhoseJournalWasAlreadyRecovered() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = UUID()
        let recovered = Self.journal(id: id, fixtures: fixtures, startedAt: Date(), status: .interrupted)
        try Self.register(recovered, in: database, started: true)
        TransferJournalStore(root: spool).save(recovered)

        let model = Self.relaunch(database: database, fixtures: fixtures, spool: spool)

        #expect(model.sessions.isEmpty)
        #expect(try database.attemptHistory(taskID: id).first?.verdict == .failed)
        #expect(try database.taskHistory().first { $0.id == id }?.verdict == .failed)
    }

    @Test func relaunchLeavesFinishedTasksAlone() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let id = try CatalogFixture.startedCopy(in: database)
        try database.finishAttempt(
            id: id, taskID: id,
            report: CatalogFixture.report(id: id, status: .verified, outcome: .verified),
            verificationProfile: .standard
        )
        let before = try CatalogFixture.snapshot(database)

        _ = Self.relaunch(database: database, fixtures: fixtures, spool: spool)

        #expect(try CatalogFixture.snapshot(database) == before)
    }
}
