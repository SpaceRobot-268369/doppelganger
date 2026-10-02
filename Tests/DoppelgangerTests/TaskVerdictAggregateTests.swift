import Foundation
import Testing
@testable import Doppelganger

/// A task aggregates its immutable attempts (offload-model.md), so the catalog
/// verdict of a task is derived from every finished attempt, never copied from
/// whichever attempt happened to finish last. A fine-grained repair covers one
/// destination's subset of the plan; the task reads Verified only when every
/// item of the plan holds a verified result at every destination.
///
/// Synthetic fixtures only: `FixtureBuilder` temp directories for the engine
/// runs, `/synthetic/...` paths for canned reports, and an in-memory catalog.
struct TaskVerdictAggregateTests {
    // MARK: - Canned-report catalog helpers

    static let source = URL(fileURLWithPath: "/synthetic/CARD_A01")
    static let raid = URL(fileURLWithPath: "/synthetic/RAID/day01")
    static let shuttle = URL(fileURLWithPath: "/synthetic/Shuttle/day01")
    static let epoch = Date(timeIntervalSince1970: 1_754_700_000)
    static let clipX = "DCIM/100MEDIA/A001.MP4"
    static let clipY = "DCIM/100MEDIA/A002.MP4"
    static let mismatch = ItemFailureReason.checksumMismatch(
        expected: "0123456789abcdef",
        actual: "1111111111111111"
    )

    /// One registered task in a fresh in-memory catalog.
    struct Catalog {
        let database: ProductDatabase
        let profile: OperatorProfile
        let taskID: UUID

        init(
            destinations: [URL] = [TaskVerdictAggregateTests.raid, TaskVerdictAggregateTests.shuttle],
            verificationProfile: VerificationProfile = .standard
        ) throws {
            let database = try ProductDatabase(inMemory: true)
            let profile = try database.activeProfile()
            let taskID = UUID()
            try database.registerTask(
                id: taskID,
                label: "A001",
                source: TaskVerdictAggregateTests.source,
                destinations: destinations,
                projectID: nil,
                operatorProfile: profile,
                algorithm: .xxh64,
                verificationProfile: verificationProfile
            )
            self.database = database
            self.profile = profile
            self.taskID = taskID
        }

        /// Registers and finishes one attempt the way AppModel does.
        @discardableResult
        func finish(_ report: TransferReport, kind: TransferAttemptKind, parent: UUID? = nil) throws -> UUID {
            let id = UUID()
            try database.registerAttempt(
                id: id,
                taskID: taskID,
                parentAttemptID: parent,
                kind: kind,
                operatorProfile: profile,
                algorithm: .xxh64,
                verificationProfile: report.verificationProfile,
                startedAt: report.startedAt
            )
            try database.finishAttempt(
                id: id,
                taskID: taskID,
                report: report,
                verificationProfile: report.verificationProfile
            )
            return id
        }

        func task() throws -> TaskHistoryRecord {
            let wanted = taskID
            let rows = try database.taskHistory()
            return try #require(rows.first(where: { $0.id == wanted }))
        }

        func attempt(_ attemptID: UUID) throws -> AttemptHistoryRecord {
            let rows = try database.attemptHistory(taskID: taskID)
            return try #require(rows.first(where: { $0.id == attemptID }))
        }
    }

    /// `step` orders the attempts: started `step` minutes after `epoch`,
    /// finished 30 s later.
    static func cannedReport(
        _ status: TransferStatus,
        step: Int,
        sourceRoot: URL = TaskVerdictAggregateTests.source,
        destinations: [URL],
        profile: VerificationProfile = .standard,
        issues: [String] = [],
        _ outcomes: [String: [URL: ItemDestinationOutcome]]
    ) -> TransferReport {
        TransferReport(
            id: UUID(),
            status: status,
            algorithm: .xxh64,
            verificationProfile: profile,
            sourceRoot: sourceRoot,
            destinations: destinations,
            startedAt: epoch.addingTimeInterval(Double(step) * 60),
            finishedAt: epoch.addingTimeInterval(Double(step) * 60 + 30),
            items: outcomes.keys.sorted().map { path in
                ItemResult(
                    item: SourceItem(relativePath: path, size: 1_000),
                    sourceDigest: "0123456789abcdef",
                    outcomes: outcomes[path] ?? [:]
                )
            },
            manifestLocations: [],
            issues: issues
        )
    }

    // MARK: - Engine-backed helpers (ported from the G04 repro)

    private static let raidName = "raid-a"
    private static let shuttleName = "shuttle-b"

    /// Parent copy to two destinations where preflight fails every pair at
    /// both (neither has enough free space). Mirrors the app: the repair
    /// requests reuse the parent manifest and the parent's source fingerprint,
    /// and each repair covers exactly the pairs that failed at its destination.
    private struct World {
        let fixtures: FixtureBuilder
        let source: URL
        let raid: URL
        let shuttle: URL
        let fingerprint: String
        let parent: TransferReport
        let parentManifest: TransferManifest

        func failedPaths(at destination: URL) -> Set<String> {
            Set(parent.items.compactMap { item -> String? in
                if case .failed = item.outcomes[destination] { return item.item.relativePath }
                return nil
            })
        }
    }

    private static func makeWorld() async throws -> World {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let raid = try fixtures.makeDestination(named: raidName)
        let shuttle = try fixtures.makeDestination(named: shuttleName)
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))

        let bothFull = FailpointFileSystem(base: RealFileSystem())
        bothFull.overrideFreeSpace(at: raid, bytes: 0)
        bothFull.overrideFreeSpace(at: shuttle, bytes: 0)
        let parent = try await EngineHarness.run(
            fileSystem: bothFull,
            source: source,
            destinations: [raid, shuttle],
            spool: fixtures.root.appendingPathComponent("parent-spool"),
            sourceFingerprint: fingerprint
        )
        try #require(parent.report.status == .failed)
        let spoolTarget = try #require(parent.report.spoolLocation)
        let manifest = try EngineHarness.decodeManifest(at: spoolTarget, shortID: parent.report.shortID)
        let world = World(
            fixtures: fixtures,
            source: source,
            raid: raid,
            shuttle: shuttle,
            fingerprint: fingerprint,
            parent: parent.report,
            parentManifest: manifest
        )
        // Every pair failed at both destinations, so each repair covers the
        // whole plan at its own destination.
        try #require(world.failedPaths(at: raid).count == EngineHarness.standardFiles.count)
        try #require(world.failedPaths(at: shuttle).count == EngineHarness.standardFiles.count)
        return world
    }

    private static func repair(
        _ world: World,
        destination: URL,
        fileSystem: any FileSystemAccess,
        spoolName: String
    ) async throws -> TransferReport {
        try await EngineHarness.run(
            fileSystem: fileSystem,
            source: world.source,
            destinations: [destination],
            spool: world.fixtures.root.appendingPathComponent(spoolName),
            sourceFingerprint: world.parentManifest.sourceFingerprint ?? world.fingerprint,
            retryManifest: world.parentManifest,
            includedRelativePaths: world.failedPaths(at: destination)
        ).report
    }

    /// Records the parent copy attempt the way AppModel does (registerTask at
    /// start, then onStarted/onFinished for the attempt).
    private static func catalogParent(
        _ world: World,
        database: ProductDatabase,
        taskID: UUID,
        parentAttemptID: UUID,
        operatorProfile: OperatorProfile
    ) throws {
        try database.registerTask(
            id: taskID,
            label: "A001",
            source: world.source,
            destinations: [world.raid, world.shuttle],
            projectID: nil,
            sourceFingerprint: world.fingerprint,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        try database.registerAttempt(
            id: parentAttemptID,
            taskID: taskID,
            kind: .copy,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        try database.finishAttempt(
            id: parentAttemptID,
            taskID: taskID,
            report: world.parent,
            verificationProfile: .standard
        )
    }

    @discardableResult
    private static func catalogRepair(
        _ report: TransferReport,
        database: ProductDatabase,
        taskID: UUID,
        parentAttemptID: UUID,
        operatorProfile: OperatorProfile
    ) throws -> UUID {
        let attemptID = UUID()
        try database.registerAttempt(
            id: attemptID,
            taskID: taskID,
            parentAttemptID: parentAttemptID,
            kind: .retry,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        try database.finishAttempt(
            id: attemptID,
            taskID: taskID,
            report: report,
            verificationProfile: .standard
        )
        return attemptID
    }

    private static func taskRecord(_ taskID: UUID, in database: ProductDatabase) throws -> TaskHistoryRecord {
        let rows = try database.taskHistory()
        return try #require(rows.first(where: { $0.id == taskID }))
    }

    // MARK: - Engine-backed repairs

    /// Retry Failures queues Repair raid-a then Repair shuttle-b (destination
    /// order, serialised on the shared source volume). raid-a is still full,
    /// so its repair fails; shuttle-b now has space, so its repair verifies
    /// and finishes last. raid-a holds no verified copy, so the task is
    /// Failed, while every attempt row keeps its own verdict.
    @Test func lastRepairToFinishCannotVerifyTaskWhileADestinationIsStillFull() async throws {
        let world = try await Self.makeWorld()

        let stillFull = FailpointFileSystem(base: RealFileSystem())
        stillFull.overrideFreeSpace(at: world.raid, bytes: 0)
        let repairRaid = try await Self.repair(
            world, destination: world.raid, fileSystem: stillFull, spoolName: "repair-raid-spool"
        )
        let repairShuttle = try await Self.repair(
            world, destination: world.shuttle, fileSystem: RealFileSystem(), spoolName: "repair-shuttle-spool"
        )
        try #require(repairRaid.status == .failed)
        try #require(repairShuttle.status == .verified)
        try #require(repairRaid.finishedAt <= repairShuttle.finishedAt)

        let database = try ProductDatabase(inMemory: true)
        let operatorProfile = try database.activeProfile()
        let taskID = UUID()
        let parentAttemptID = UUID()
        try Self.catalogParent(
            world, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )
        let raidAttemptID = try Self.catalogRepair(
            repairRaid, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )
        let shuttleAttemptID = try Self.catalogRepair(
            repairShuttle, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )

        let task = try Self.taskRecord(taskID, in: database)
        #expect(task.verdict == .failed,
                "task must read Failed while every pair at raid-a is still failed")
        #expect(task.lifecycle == .failed)

        let attempts = try database.attemptHistory(taskID: taskID)
        #expect(attempts.count == 3)
        let parentRow = try #require(attempts.first(where: { $0.id == parentAttemptID }))
        let raidRow = try #require(attempts.first(where: { $0.id == raidAttemptID }))
        let shuttleRow = try #require(attempts.first(where: { $0.id == shuttleAttemptID }))
        #expect(parentRow.verdict == .failed)
        #expect(raidRow.verdict == .failed)
        #expect(shuttleRow.verdict == .verified)
        #expect(shuttleRow.lifecycle == .complete)
    }

    /// Repair raid-a verifies while Repair shuttle-b is still queued (or was
    /// withdrawn). The task stays Failed while shuttle-b has no verified copy
    /// of anything; once shuttle-b's repair verifies too, the task completes.
    @Test func verifiedRepairOfOneDestinationLeavesTaskFailedUntilTheOtherIsRepaired() async throws {
        let world = try await Self.makeWorld()

        let repairRaid = try await Self.repair(
            world, destination: world.raid, fileSystem: RealFileSystem(), spoolName: "repair-raid-spool"
        )
        try #require(repairRaid.status == .verified)

        let database = try ProductDatabase(inMemory: true)
        let operatorProfile = try database.activeProfile()
        let taskID = UUID()
        let parentAttemptID = UUID()
        try Self.catalogParent(
            world, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )
        try Self.catalogRepair(
            repairRaid, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )

        let afterRaid = try Self.taskRecord(taskID, in: database)
        #expect(afterRaid.verdict == .failed,
                "task must read Failed while shuttle-b was never repaired")
        #expect(afterRaid.lifecycle == .failed)

        let repairShuttle = try await Self.repair(
            world, destination: world.shuttle, fileSystem: RealFileSystem(), spoolName: "repair-shuttle-spool"
        )
        try #require(repairShuttle.status == .verified)
        try Self.catalogRepair(
            repairShuttle, database: database, taskID: taskID,
            parentAttemptID: parentAttemptID, operatorProfile: operatorProfile
        )

        let afterBoth = try Self.taskRecord(taskID, in: database)
        #expect(afterBoth.verdict == .verified,
                "repairs that verify every failed pair at every destination complete the task")
        #expect(afterBoth.lifecycle == .complete)
    }

    // MARK: - Canned repairs

    /// One repair fails and its sibling verifies, in either finishing order:
    /// the task is Failed both ways. A later repair of the still-failed
    /// destination completes it.
    @Test(arguments: [true, false])
    func repairVerdictIsNotLastWriterWins(verifiedRepairFinishesLast: Bool) throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX
        let catalog = try Catalog()
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], [
                x: [raid: .failed(.destinationFull), shuttle: .failed(.destinationFull)],
            ]),
            kind: .copy
        )

        let failedRaid = Self.cannedReport(
            .failed, step: verifiedRepairFinishesLast ? 1 : 2, destinations: [raid],
            [x: [raid: .failed(.destinationUnmounted)]]
        )
        let verifiedShuttle = Self.cannedReport(
            .verified, step: verifiedRepairFinishesLast ? 2 : 1, destinations: [shuttle],
            [x: [shuttle: .verified]]
        )
        let finishingOrder = verifiedRepairFinishesLast
            ? [failedRaid, verifiedShuttle]
            : [verifiedShuttle, failedRaid]
        for report in finishingOrder {
            try catalog.finish(report, kind: .retry, parent: parent)
        }

        let afterSiblings = try catalog.task()
        #expect(afterSiblings.verdict == .failed)
        #expect(afterSiblings.lifecycle == .failed)

        try catalog.finish(
            Self.cannedReport(.verified, step: 3, destinations: [raid], [x: [raid: .verified]]),
            kind: .retry,
            parent: parent
        )
        let afterRepair = try catalog.task()
        #expect(afterRepair.verdict == .verified)
        #expect(afterRepair.lifecycle == .complete)
    }

    /// F03 happy path: the parent verified everything except one pair at one
    /// destination; repairing that pair verifies the task.
    @Test func repairingTheOnlyFailedDestinationVerifiesTheTask() throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let catalog = try Catalog()
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], [
                x: [raid: .verified, shuttle: .failed(Self.mismatch)],
                y: [raid: .verified, shuttle: .verified],
            ]),
            kind: .copy
        )
        let parentTask = try catalog.task()
        #expect(parentTask.verdict == .failed)

        try catalog.finish(
            Self.cannedReport(.verified, step: 1, destinations: [shuttle], [x: [shuttle: .verified]]),
            kind: .retry,
            parent: parent
        )

        let task = try catalog.task()
        #expect(task.verdict == .verified)
        #expect(task.lifecycle == .complete)
    }

    /// Same shape as `ReportFixtures.failedReport()`: the repairs cover only
    /// the failed pairs, so the skipped pair (Y at shuttle) still has no
    /// verified copy and the task stays Failed.
    @Test func skippedPairsKeepTheTaskFailedAfterEveryFailedPairIsRepaired() throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let catalog = try Catalog()
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], [
                x: [raid: .verified, shuttle: .failed(Self.mismatch)],
                y: [
                    raid: .failed(.sourceUnreadable(detail: "read failed: Input/output error")),
                    shuttle: .skipped(.destinationUnavailable),
                ],
            ]),
            kind: .copy
        )
        try catalog.finish(
            Self.cannedReport(.verified, step: 1, destinations: [shuttle], [x: [shuttle: .verified]]),
            kind: .retry,
            parent: parent
        )
        try catalog.finish(
            Self.cannedReport(.verified, step: 2, destinations: [raid], [y: [raid: .verified]]),
            kind: .retry,
            parent: parent
        )

        let task = try catalog.task()
        #expect(task.verdict == .failed, "Y at shuttle was skipped and never repaired")
        #expect(task.lifecycle == .failed)
    }

    /// A parent that failed for a transfer-level reason (here, evidence it
    /// could not write) does not vouch for the pairs it lists as verified, so
    /// repairing its one failed pair cannot verify the task. The control run
    /// without the issue shows the issue is what keeps it Failed.
    @Test(arguments: [true, false])
    func aTransferLevelFailureIsNotRepairedByPairRepairs(parentRecordedEvidenceFailure: Bool) throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let issues = parentRecordedEvidenceFailure
            ? ["Could not write complete transfer evidence to: /synthetic/Shuttle/day01"]
            : []
        let catalog = try Catalog()
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], issues: issues, [
                x: [raid: .failed(.writeFailed(detail: "No space left on device")), shuttle: .verified],
                y: [raid: .verified, shuttle: .verified],
            ]),
            kind: .copy
        )
        try catalog.finish(
            Self.cannedReport(.verified, step: 1, destinations: [raid], [x: [raid: .verified]]),
            kind: .retry,
            parent: parent
        )

        let task = try catalog.task()
        if parentRecordedEvidenceFailure {
            #expect(task.verdict == .failed,
                    "a pair repair cannot vouch for evidence the parent failed to write")
            #expect(task.lifecycle == .failed)
        } else {
            #expect(task.verdict == .verified)
            #expect(task.lifecycle == .complete)
        }
    }

    /// For a task with a single attempt the derived verdict equals the
    /// attempt's own verdict, and lifecycle follows today's mapping.
    @Test(arguments: [
        TransferStatus.verified,
        .transferredPendingVerification,
        .failed,
        .cancelled,
        .paused,
    ])
    func singleAttemptTasksKeepTheirAttemptVerdict(status: TransferStatus) throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let profile: VerificationProfile = status == .transferredPendingVerification ? .fast : .standard
        let outcomes: [String: [URL: ItemDestinationOutcome]]
        let expectedVerdict: TransferVerdict
        let expectedLifecycle: TaskLifecycle
        switch status {
        case .verified:
            outcomes = [
                x: [raid: .verified, shuttle: .verified],
                y: [raid: .verified, shuttle: .verified],
            ]
            expectedVerdict = .verified
            expectedLifecycle = .complete
        case .transferredPendingVerification:
            outcomes = [
                x: [raid: .transferredPendingVerification, shuttle: .transferredPendingVerification],
                y: [raid: .transferredPendingVerification, shuttle: .transferredPendingVerification],
            ]
            expectedVerdict = .transferredPendingVerification
            expectedLifecycle = .transferredPendingVerification
        case .failed:
            outcomes = [
                x: [raid: .verified, shuttle: .failed(Self.mismatch)],
                y: [raid: .verified, shuttle: .verified],
            ]
            expectedVerdict = .failed
            expectedLifecycle = .failed
        case .cancelled:
            outcomes = [
                x: [raid: .verified, shuttle: .verified],
                y: [raid: .skipped(.cancelled), shuttle: .skipped(.cancelled)],
            ]
            expectedVerdict = .cancelled
            expectedLifecycle = .cancelled
        case .paused:
            outcomes = [
                x: [raid: .verified, shuttle: .verified],
                y: [raid: .skipped(.paused), shuttle: .skipped(.paused)],
            ]
            expectedVerdict = .paused
            expectedLifecycle = .paused
        }

        let catalog = try Catalog(verificationProfile: profile)
        let attemptID = try catalog.finish(
            Self.cannedReport(status, step: 0, destinations: [raid, shuttle], profile: profile, outcomes),
            kind: .copy
        )

        let task = try catalog.task()
        #expect(task.verdict == expectedVerdict)
        #expect(task.lifecycle == expectedLifecycle)
        let attempt = try catalog.attempt(attemptID)
        #expect(attempt.verdict == expectedVerdict)
        #expect(attempt.lifecycle == expectedLifecycle)
    }

    /// A Fast repair of the one failed pair leaves every pair copied but
    /// awaiting read-back: the task is pending verification, neither green
    /// nor failed.
    @Test func fastRepairLeavesTheTaskPendingVerification() throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let catalog = try Catalog(verificationProfile: .fast)
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], profile: .fast, [
                x: [raid: .failed(.destinationFull), shuttle: .transferredPendingVerification],
                y: [raid: .transferredPendingVerification, shuttle: .transferredPendingVerification],
            ]),
            kind: .copy
        )
        try catalog.finish(
            Self.cannedReport(
                .transferredPendingVerification, step: 1, destinations: [raid], profile: .fast,
                [x: [raid: .transferredPendingVerification]]
            ),
            kind: .retry,
            parent: parent
        )

        let task = try catalog.task()
        #expect(task.verdict == .transferredPendingVerification)
        #expect(task.lifecycle == .transferredPendingVerification)
    }

    /// A linked verification of one destination of a multi-destination Fast
    /// task lifts only that destination's pairs: the task stays pending until
    /// the other destination is verified too. The copy attempt row keeps its
    /// own verdict throughout.
    @Test func linkedVerificationOfOneDestinationKeepsAMultiDestinationFastTaskPending() throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let catalog = try Catalog(verificationProfile: .fast)
        let copy = try catalog.finish(
            Self.cannedReport(.transferredPendingVerification, step: 0, destinations: [raid, shuttle], profile: .fast, [
                x: [raid: .transferredPendingVerification, shuttle: .transferredPendingVerification],
                y: [raid: .transferredPendingVerification, shuttle: .transferredPendingVerification],
            ]),
            kind: .copy
        )
        let pendingTask = try catalog.task()
        #expect(pendingTask.verdict == .transferredPendingVerification)

        try catalog.finish(
            Self.cannedReport(.verified, step: 1, sourceRoot: raid, destinations: [raid], [
                x: [raid: .verified],
                y: [raid: .verified],
            ]),
            kind: .verification,
            parent: copy
        )
        let afterRaid = try catalog.task()
        #expect(afterRaid.verdict == .transferredPendingVerification,
                "shuttle's copies still await read-back")
        #expect(afterRaid.lifecycle == .transferredPendingVerification)

        try catalog.finish(
            Self.cannedReport(.verified, step: 2, sourceRoot: shuttle, destinations: [shuttle], [
                x: [shuttle: .verified],
                y: [shuttle: .verified],
            ]),
            kind: .verification,
            parent: copy
        )
        let afterBoth = try catalog.task()
        #expect(afterBoth.verdict == .verified)
        #expect(afterBoth.lifecycle == .complete)

        let copyRow = try catalog.attempt(copy)
        #expect(copyRow.verdict == .transferredPendingVerification)
        #expect(copyRow.lifecycle == .transferredPendingVerification)
    }

    /// Nothing edits a failure into success: a passing linked verification
    /// cannot lift a pair the copy recorded as failed.
    @Test func aLinkedVerificationNeverTurnsAFailedPairIntoSuccess() throws {
        let raid = Self.raid, shuttle = Self.shuttle, x = Self.clipX, y = Self.clipY
        let catalog = try Catalog()
        let parent = try catalog.finish(
            Self.cannedReport(.failed, step: 0, destinations: [raid, shuttle], [
                x: [raid: .failed(Self.mismatch), shuttle: .verified],
                y: [raid: .verified, shuttle: .verified],
            ]),
            kind: .copy
        )
        try catalog.finish(
            Self.cannedReport(.verified, step: 1, sourceRoot: raid, destinations: [raid], [
                x: [raid: .verified],
                y: [raid: .verified],
            ]),
            kind: .verification,
            parent: parent
        )

        let task = try catalog.task()
        #expect(task.verdict == .failed)
        #expect(task.lifecycle == .failed)
    }
}

/// Pure checks of the fail-closed task projection.
struct TaskVerdictRollupTests {
    private typealias PairState = TaskVerdictRollup.PairState
    private typealias Results = [String: [String: TaskVerdictRollup.PairState]]

    private static let raid = "/synthetic/RAID/day01"
    private static let shuttle = "/synthetic/Shuttle/day01"
    private static let clip = "DCIM/100MEDIA/A001.MP4"

    private static func attempt(
        _ kind: TransferAttemptKind,
        _ verdict: TransferVerdict,
        hasIssues: Bool = false,
        results: Results?
    ) -> TaskVerdictRollup.Attempt {
        TaskVerdictRollup.Attempt(
            kind: kind, verdict: verdict, vouching: hasIssues ? .nowhere : .everywhere, results: results
        )
    }

    private static func everyPairVerified() -> Results {
        [clip: [raid: .verified, shuttle: .verified]]
    }

    @Test func unknownStatusIsNeverSuccess() {
        for status in ["skipped", "failed", "verified-ish", "Verified", "pending", ""] {
            #expect(PairState(manifestStatus: status) == .unverified, "manifest status \(status)")
        }
        #expect(PairState(manifestStatus: "verified") == .verified)
        #expect(PairState(manifestStatus: "transferred-pending-verification") == .pendingVerification)

        let results: Results = [
            Self.clip: [Self.raid: .verified, Self.shuttle: PairState(manifestStatus: "verified-ish")],
        ]
        let verdict = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [Self.attempt(.copy, .verified, results: results)]
        )
        #expect(verdict == .failed)
    }

    @Test func unreadableRecordsFailClosed() {
        let destinations = [Self.raid, Self.shuttle]
        let onlyUnreadable = TaskVerdictRollup.verdict(
            destinations: destinations,
            attempts: [Self.attempt(.copy, .verified, results: nil)]
        )
        #expect(onlyUnreadable == .failed)

        let unreadablePending = TaskVerdictRollup.verdict(
            destinations: destinations,
            attempts: [Self.attempt(.copy, .transferredPendingVerification, results: nil)]
        )
        #expect(unreadablePending == .failed)

        let readableThenUnreadable = TaskVerdictRollup.verdict(
            destinations: destinations,
            attempts: [
                Self.attempt(.copy, .verified, results: Self.everyPairVerified()),
                Self.attempt(.retry, .verified, results: nil),
            ]
        )
        #expect(readableThenUnreadable == .failed)
    }

    @Test func contactSheetAttemptsAreIgnored() {
        let verdict = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [
                Self.attempt(.copy, .verified, results: Self.everyPairVerified()),
                Self.attempt(.contactSheet, .failed, hasIssues: true, results: nil),
            ]
        )
        #expect(verdict == .verified)
    }

    @Test func noFinishedAttemptReturnsNil() {
        let none = TaskVerdictRollup.verdict(destinations: [Self.raid, Self.shuttle], attempts: [])
        #expect(none == nil)

        let onlyContactSheet = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [Self.attempt(.contactSheet, .verified, results: [:])]
        )
        #expect(onlyContactSheet == nil)
    }

    @Test func emptyPlanIsNeverVerified() {
        let noItems = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [Self.attempt(.copy, .verified, results: [:])]
        )
        #expect(noItems == .failed)

        let noDestinations = TaskVerdictRollup.verdict(
            destinations: [],
            attempts: [Self.attempt(.copy, .verified, results: [:])]
        )
        #expect(noDestinations == .failed)
    }

    @Test func aFailedDuplicateRepairNeverLowersVerifiedPairs() {
        let parent = Self.attempt(.copy, .failed, results: [Self.clip: [Self.raid: .verified, Self.shuttle: .unverified]])
        let repair = Self.attempt(.retry, .verified, results: [Self.clip: [Self.shuttle: .verified]])
        // The same Retry clicked again; this time the drive is full.
        let duplicate = Self.attempt(.retry, .failed, results: [Self.clip: [Self.shuttle: .unverified]])
        let verdict = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [parent, repair, duplicate]
        )
        #expect(verdict == .verified)

        // A failed repair of a pair nothing has verified yet still fails it.
        let stillFailed = TaskVerdictRollup.verdict(
            destinations: [Self.raid, Self.shuttle],
            attempts: [parent, duplicate]
        )
        #expect(stillFailed == .failed)
    }

    @Test func evidenceMissingAtOneDestinationOnlyUnvouchesThatDestination() {
        let results: Results = [Self.clip: [Self.raid: .verified, Self.shuttle: .unverified]]
        let parent = TaskVerdictRollup.Attempt(
            kind: .copy, verdict: .failed, vouching: .only([Self.raid]), results: results
        )
        let repair = Self.attempt(.retry, .verified, results: [Self.clip: [Self.shuttle: .verified]])
        #expect(
            TaskVerdictRollup.verdict(destinations: [Self.raid, Self.shuttle], attempts: [parent, repair])
                == .verified
        )

        // Evidence missing at the destination that was NOT repaired keeps the
        // task failed: nothing vouches for raid.
        let unvouchedRaid = TaskVerdictRollup.Attempt(
            kind: .copy, verdict: .failed, vouching: .only([Self.shuttle]), results: results
        )
        #expect(
            TaskVerdictRollup.verdict(destinations: [Self.raid, Self.shuttle], attempts: [unvouchedRaid, repair])
                == .failed
        )

        // Any other transfer-level issue vouches for nothing.
        let vetoed = TaskVerdictRollup.Attempt(
            kind: .copy, verdict: .failed, vouching: .nowhere, results: results
        )
        #expect(
            TaskVerdictRollup.verdict(destinations: [Self.raid, Self.shuttle], attempts: [vetoed, repair])
                == .failed
        )
    }
}
