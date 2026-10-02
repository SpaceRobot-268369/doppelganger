import Foundation
import Testing
@testable import Doppelganger

/// How a test damages an offered attempt's saved spool record.
enum PausedRecordTamper: CaseIterable, Sendable {
    case missing, claimsVerified, anotherAttempt, anotherSourcePlan, recordsAFailure
}

/// L2: a paused or Fast-pending attempt survives a relaunch with its next step
/// (findings app-orchestration-6, app-services-2), and quitting warns only
/// when something would really be lost. Supersedes
/// Repro_G11_resume_lifecycle.repro_pausedAttemptIsRestoredAfterRelaunch.
///
/// Every run writes into a FixtureBuilder temp directory and every AppModel
/// recovers from an injected temp spool over an in-memory catalog. No test
/// builds a non-recovered TransferSession or reaches AppModel.resume's
/// success path: both would write a journal into the host's spool.
@MainActor
struct PausedAttemptRestoreTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    /// One real paused (or Fast-pending) run plus the journal the app keeps
    /// for it, all under one fixture root. Shared with LinkedAttemptReleaseTests
    /// and RetryAsNewOffloadReviewTests.
    struct World {
        let fixtures: FixtureBuilder
        let source: URL
        let destination: URL
        let spool: URL
        let run: EngineHarness.Run
        let journal: TransferJournal

        var manifestName: String { ManifestWriter.manifestFileName(shortID: run.report.shortID) }
        var spoolManifest: URL {
            spool.appendingPathComponent(run.report.shortID, isDirectory: true)
                .appendingPathComponent(manifestName)
        }
        var journalURL: URL {
            spool.appendingPathComponent(run.report.shortID, isDirectory: true)
                .appendingPathComponent("transfer-journal.json")
        }
    }

    static func makeWorld(
        profile: VerificationProfile = .standard,
        pause: Bool = true,
        selection: Set<String>? = nil
    ) async throws -> World {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "relaunch-destination")
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let planned = try RealFileSystem().enumerate(root: source)
            .filter { selection?.contains($0.relativePath) ?? true }
        let fingerprint = SourcePlanFingerprint.make(planned)
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        fileSystem.delayWrites(microseconds: 500)
        // Pauses after the first file reaches its complete-file boundary, the
        // same way PauseResumeTests does.
        let afterFirstFile: @Sendable (TransferEvent) -> Bool = { event in
            if case .progress(let progress) = event {
                return progress.copiedBytes > 32 * 1024
            }
            return false
        }
        let run = try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: spool,
            verificationProfile: profile,
            sourceFingerprint: fingerprint,
            includedRelativePaths: selection,
            chunkSize: 4 * 1024,
            pauseWhen: pause ? afterFirstFile : nil
        )
        // What TransferSession keeps for the run: the journal written at
        // creation, closed with the production verdict mapping.
        var journal = TransferJournal(
            id: run.report.id,
            taskID: run.report.taskID,
            attemptKind: .copy,
            label: "20260810_A001",
            source: source,
            destinationBases: [destination],
            destinations: [destination],
            algorithm: .xxh64,
            verificationProfile: profile,
            sourceFingerprint: fingerprint,
            allowSameVolume: true,
            createdAt: run.report.startedAt,
            startedAt: run.report.startedAt,
            itemCount: run.report.items.count,
            totalBytes: run.report.totalBytes,
            status: .running,
            includedRelativePaths: selection?.sorted()
        )
        journal.recordVerdict(of: run.report)
        TransferJournalStore(root: spool).save(journal)
        return World(
            fixtures: fixtures, source: source, destination: destination,
            spool: spool, run: run, journal: journal
        )
    }

    /// A fresh AppModel recovering from the world's spool only.
    static func relaunch(_ world: World) throws -> AppModel {
        let suiteName = "PausedRestore-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return AppModel(
            selectionStore: MemorySelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
            productStore: ProductStore(
                database: try ProductDatabase(inMemory: true),
                avatars: AvatarStore(root: world.fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: world.spool
        )
    }

    private static func rewriteSpoolManifest(
        _ world: World,
        _ change: (inout TransferManifest) -> Void
    ) throws {
        var manifest = try ManifestWriter.decode(Data(contentsOf: world.spoolManifest))
        change(&manifest)
        try ManifestWriter.jsonData(for: manifest).write(to: world.spoolManifest, options: .atomic)
    }

    // MARK: - Restore

    /// Port of repro_pausedAttemptIsRestoredAfterRelaunch, tightened: the card
    /// returns paused with its own record, and that record resumes to Verified.
    @Test func aPausedAttemptComesBackWithItsResumeAfterRelaunch() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        let journalBytes = try Data(contentsOf: world.journalURL)

        let model = try Self.relaunch(world)

        #expect(model.sessions.count == 1)
        let card = try #require(model.sessions.first { $0.id == world.run.report.id })
        #expect(card.report?.status == .paused)
        #expect(!card.isActive)
        #expect(!card.isRecovered)
        #expect(!card.headline.isProblem)
        #expect(card.destinationState(world.destination) == .paused)
        #expect(card.manifestURL?.path == world.spoolManifest.path)
        for item in world.run.report.items {
            let path = item.item.relativePath
            #expect(card.report?.outcome(path, at: world.destination)
                == world.run.report.outcome(path, at: world.destination), "\(path)")
        }
        #expect(model.continuation(of: card.id) == .open)

        let manifest = try model.resumeManifest(for: card)
        #expect(manifest.transferID == world.run.report.id.uuidString.lowercased())
        let scope = try #require(AppModel.resumeScope(
            pausedScope: card.includedRelativePaths,
            pausedFingerprint: card.sourceFingerprint,
            manifest: manifest
        ))
        #expect(scope.includedRelativePaths == nil)
        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("resume-spool"),
            sourceFingerprint: scope.sourceFingerprint,
            resumeManifest: manifest,
            includedRelativePaths: scope.includedRelativePaths
        )
        #expect(resumed.report.status == .verified)
        for spec in EngineHarness.standardFiles {
            #expect(try world.fixtures.bytes(at: world.destination.appendingPathComponent(spec.path)) == spec.bytes)
        }

        // Restore is read-only, and the card keeps coming back.
        #expect(try Data(contentsOf: world.journalURL) == journalBytes)
        #expect(try Self.relaunch(world).sessions.map(\.id) == [world.run.report.id])
    }

    /// The Fast half of the finding: a copy waiting for read-back keeps its
    /// card, never offered as verified.
    @Test func aFastPendingAttemptComesBackAwaitingVerification() async throws {
        let world = try await Self.makeWorld(profile: .fast, pause: false)
        try #require(world.run.report.status == .transferredPendingVerification)

        let model = try Self.relaunch(world)

        let card = try #require(model.sessions.first)
        #expect(model.sessions.count == 1)
        #expect(card.report?.status == .transferredPendingVerification)
        #expect(card.verificationProfile == .fast)
        #expect(card.destinationState(world.destination) == .pendingVerification)
        #expect(card.sourceEjectEligibility(among: model.sessions, mounted: []) == .notOffered)
        #expect(card.manifestURL?.path == world.spoolManifest.path)
        #expect(!card.isRecovered)
    }

    /// The repro's fixture is the pre-fix journal shape (no offer). Restoring
    /// those would resurrect every pause and Fast run ever made at the first
    /// launch after upgrade, so they stay history.
    @Test func journalsThatWereNeverOfferedStayHistory() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        var legacy = world.journal
        legacy.offeredAtLaunch = nil
        TransferJournalStore(root: world.spool).save(legacy)

        #expect(try Self.relaunch(world).sessions.isEmpty)
    }

    @Test(arguments: [
        TransferStatus.paused, .transferredPendingVerification, .verified, .failed, .cancelled,
    ])
    func recordVerdictOffersOnlyPausedAndPending(_ status: TransferStatus) {
        var journal = TransferJournal(
            id: UUID(),
            label: "Day 01",
            source: URL(fileURLWithPath: "/Volumes/CARD"),
            destinationBases: [URL(fileURLWithPath: "/Volumes/RAID")],
            destinations: [URL(fileURLWithPath: "/Volumes/RAID/Day 01")],
            algorithm: .xxh64,
            allowSameVolume: false,
            createdAt: Date(),
            startedAt: Date(),
            itemCount: 1,
            totalBytes: 1,
            status: .running
        )
        journal.recordVerdict(status)

        #expect(journal.status.rawValue == status.rawValue)
        let offered = status == .paused || status == .transferredPendingVerification
        #expect(journal.offeredAtLaunch == (offered ? true : nil))
    }

    @Test func removingTheCardEndsTheOfferButKeepsEveryRecord() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        let destinationBefore = try world.fixtures.digestSnapshot(of: world.destination)
        let model = try Self.relaunch(world)
        let card = try #require(model.sessions.first)

        model.remove(card)

        #expect(model.sessions.isEmpty)
        #expect(try Self.relaunch(world).sessions.isEmpty)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(TransferJournal.self, from: Data(contentsOf: world.journalURL))
        #expect(journal.status == .paused)
        #expect(journal.offeredAtLaunch == false)
        #expect(FileManager.default.fileExists(atPath: world.spoolManifest.path))
        #expect(try world.fixtures.digestSnapshot(of: world.destination) == destinationBefore)
    }

    /// A resume that started carries the attempt on; one that was only queued
    /// when the app quit wrote nothing, so the pause keeps its Resume.
    @Test(arguments: [true, false])
    func aResumeThatStartedCarriesTheAttemptOn(childStarted: Bool) async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        var child = TransferJournal(
            id: UUID(),
            taskID: world.run.report.taskID,
            parentAttemptID: world.run.report.id,
            attemptKind: .resume,
            label: world.journal.label,
            source: world.source,
            destinationBases: [world.destination],
            destinations: [world.destination],
            algorithm: .xxh64,
            verificationProfile: .standard,
            sourceFingerprint: world.journal.sourceFingerprint,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: childStarted ? Date() : nil,
            itemCount: 0,
            totalBytes: 0,
            status: .interrupted
        )
        if childStarted { child.recordVerdict(.verified) }
        TransferJournalStore(root: world.spool).save(child)

        let model = try Self.relaunch(world)

        if childStarted {
            #expect(model.sessions.isEmpty)
        } else {
            #expect(model.sessions.map(\.id) == [world.run.report.id])
            #expect(model.continuation(of: world.run.report.id) == .open)
        }
    }

    /// An offered attempt whose record is missing or does not match never
    /// comes back resumable or green, and never vanishes silently.
    @Test(arguments: PausedRecordTamper.allCases)
    func anOfferedAttemptWhoseRecordDoesNotCheckOutReturnsForReviewOnly(_ tamper: PausedRecordTamper) async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        switch tamper {
        case .missing:
            try FileManager.default.removeItem(at: world.spoolManifest)
        case .claimsVerified:
            try Self.rewriteSpoolManifest(world) { $0.status = TransferStatus.verified.rawValue }
        case .anotherAttempt:
            try Self.rewriteSpoolManifest(world) { $0.transferID = UUID().uuidString.lowercased() }
        case .anotherSourcePlan:
            try Self.rewriteSpoolManifest(world) { $0.sourceFingerprint = "another-plan" }
        case .recordsAFailure:
            try Self.rewriteSpoolManifest(world) { $0.items[0].results[0].status = "failed" }
        }
        let destinationBefore = try world.fixtures.digestSnapshot(of: world.destination)
        let journalBytes = try Data(contentsOf: world.journalURL)

        let model = try Self.relaunch(world)

        let card = try #require(model.sessions.first { $0.id == world.run.report.id })
        #expect(card.report?.status == .failed)
        #expect(card.isRecovered)
        #expect(card.headline.isProblem)
        #expect(card.report?.issues == [AppModel.unreadableOfferIssue])
        #expect(throws: ResumeRefusal.self) { try model.resumeManifest(for: card) }
        #expect(model.quitImpact == QuitImpact())
        #expect(try world.fixtures.digestSnapshot(of: world.destination) == destinationBefore)
        #expect(try Data(contentsOf: world.journalURL) == journalBytes)
    }

    /// Why `.paused` must never join `isUnfinished`: recovery deletes an
    /// unfinished run's evidence.
    @Test func interruptedRecoveryLeavesOfferedEvidenceAlone() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)

        #expect(TransferJournalStore(root: world.spool).recoverInterrupted().isEmpty)
        #expect(FileManager.default.fileExists(atPath: world.spoolManifest.path))
        #expect(FileManager.default.fileExists(
            atPath: world.destination.appendingPathComponent(world.manifestName).path
        ))
    }

    // MARK: - Quit

    @Test func quittingAsksOnlyWhenAnUnfinishedAttemptCouldNotReturn() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try Self.relaunch(world)
        try #require(model.sessions.count == 1)

        #expect(model.quitImpact == QuitImpact())
        #expect(!model.quitImpact.requiresConfirmation)

        // The saved record is gone: the card would not come back as it is.
        try FileManager.default.removeItem(at: world.spoolManifest)
        let impact = model.quitImpact
        #expect(impact == QuitImpact(unrecoverable: 1))
        #expect(impact.requiresConfirmation)
        #expect(impact.title == L10n.text("Some transfers cannot be restored"))
        #expect(!impact.message.isEmpty)
    }

    /// AppModel counts live running and queued sessions; building one here
    /// would write a journal into the host's spool, so the rule is pinned on
    /// the value it produces.
    @Test func runningAndQueuedWorkAlwaysAsks() {
        let running = QuitImpact(running: 1)
        #expect(running.requiresConfirmation)
        #expect(running.title == L10n.text("Transfers are still running"))
        #expect(running.message.contains(L10n.text(
            "Quitting interrupts active copies. Their partial output will be preserved and shown as needing attention next time Doppelganger opens."
        )))
        let queued = QuitImpact(queued: 1)
        #expect(queued.requiresConfirmation)
        #expect(queued.title == L10n.text("Transfers are waiting to start"))
        #expect(!QuitImpact().requiresConfirmation)
    }

    // MARK: - Resume preconditions

    @Test func resumeBuildsOnlyOnThisAttemptsRecordOnTheDrivesItPausedOn() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try Self.relaunch(world)
        let card = try #require(model.sessions.first)
        _ = try model.resumeManifest(for: card)

        // A swapped or cleaned drive no longer holds this attempt's record.
        let record = world.destination.appendingPathComponent(world.manifestName)
        let parked = world.fixtures.root.appendingPathComponent("parked-record.json")
        try FileManager.default.moveItem(at: record, to: parked)
        #expect(throws: ResumeRefusal.self) { try model.resumeManifest(for: card) }
        try FileManager.default.moveItem(at: parked, to: record)
        _ = try model.resumeManifest(for: card)

        // The card is out of the reader.
        let parkedCard = world.fixtures.root.appendingPathComponent("parked-card", isDirectory: true)
        try FileManager.default.moveItem(at: world.source, to: parkedCard)
        #expect(throws: ResumeRefusal.self) { try model.resumeManifest(for: card) }
        try FileManager.default.moveItem(at: parkedCard, to: world.source)
        _ = try model.resumeManifest(for: card)

        #expect(model.sessions.count == 1)
    }

    /// The refusal reaches the operator and creates nothing. Resume is called
    /// only once the refusal is proven, so it can never build a session here.
    @Test func aRefusedResumeReportsWhyAndCreatesNoAttempt() async throws {
        let world = try await Self.makeWorld()
        try #require(world.run.report.status == .paused)
        let model = try Self.relaunch(world)
        let card = try #require(model.sessions.first)
        try FileManager.default.removeItem(at: world.destination.appendingPathComponent(world.manifestName))
        _ = try #require(throws: ResumeRefusal.self) { try model.resumeManifest(for: card) }

        model.productStore.clearError()
        model.resume(card)

        #expect(model.sessions.map(\.id) == [card.id])
        #expect(model.continuation(of: card.id) == .open)
        #expect(model.productStore.lastError == L10n.format(
            "Resume needs every destination this transfer paused on. Reconnect %@, or use Retry as New Offload.",
            world.destination.lastPathComponent
        ))
    }

    /// L2 + L3 together: a paused selection comes back with its reviewed scope
    /// and resumes exactly that selection.
    @Test func aRestoredSelectionPauseResumesExactlyTheSelection() async throws {
        let selection: Set<String> = ["DCIM/100MEDIA/a.bin", "DCIM/100MEDIA/b.bin"]
        let world = try await Self.makeWorld(selection: selection)
        try #require(world.run.report.status == .paused)
        let model = try Self.relaunch(world)
        let card = try #require(model.sessions.first)
        #expect(card.includedRelativePaths == selection)

        let manifest = try model.resumeManifest(for: card)
        let scope = try #require(AppModel.resumeScope(
            pausedScope: card.includedRelativePaths,
            pausedFingerprint: card.sourceFingerprint,
            manifest: manifest
        ))
        #expect(scope.includedRelativePaths == selection)
        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: world.source,
            destinations: [world.destination],
            spool: world.fixtures.root.appendingPathComponent("resume-spool"),
            sourceFingerprint: scope.sourceFingerprint,
            resumeManifest: manifest,
            includedRelativePaths: scope.includedRelativePaths
        )
        #expect(resumed.report.status == .verified)
        #expect(Set(resumed.report.items.map(\.item.relativePath)) == selection)
        #expect(!FileManager.default.fileExists(
            atPath: world.destination.appendingPathComponent("MISC/c.txt").path
        ))
    }

    /// A restored selection whose saved scope no longer matches its record is
    /// refused before any attempt exists.
    @Test func aRestoredSelectionWhoseScopeDoesNotMatchIsRefused() async throws {
        let selection: Set<String> = ["DCIM/100MEDIA/a.bin", "DCIM/100MEDIA/b.bin"]
        let world = try await Self.makeWorld(selection: selection)
        try #require(world.run.report.status == .paused)
        var widened = world.journal
        widened.includedRelativePaths = (selection.union(["MISC/c.txt"])).sorted()
        TransferJournalStore(root: world.spool).save(widened)
        let model = try Self.relaunch(world)
        let card = try #require(model.sessions.first)
        let manifest = try model.resumeManifest(for: card)
        try #require(AppModel.resumeScope(
            pausedScope: card.includedRelativePaths,
            pausedFingerprint: card.sourceFingerprint,
            manifest: manifest
        ) == nil)

        model.productStore.clearError()
        model.resume(card)

        #expect(model.sessions.map(\.id) == [card.id])
        #expect(model.productStore.lastError == L10n.text(
            "The paused attempt's reviewed file scope cannot be confirmed; it cannot be resumed safely."
        ))
    }

    // MARK: - Strings

    @Test func quitAndResumeTextShipsInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings",
            subdirectory: nil, localization: "zh-Hans"
        ))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for key in [
            "Connect the source %@ to resume this transfer.",
            "Resume needs every destination this transfer paused on. Reconnect %@, or use Retry as New Offload.",
            "Transfers are still running",
            "Transfers are waiting to start",
            "Some transfers cannot be restored",
            "Quitting interrupts active copies. Their partial output will be preserved and shown as needing attention next time Doppelganger opens.",
            "Queued transfers have not started and will not run.",
            "Some paused or unverified transfers could not be saved for next time and will not reopen as they are now. Keep the source media.",
            "Keep Running",
            "Quit Anyway",
        ] {
            let value = try #require(catalog[key], "zh-Hans is missing \(key)")
            #expect(!value.isEmpty)
            #expect(value != key)
            if key.contains("%@") { #expect(value.contains("%@"), "\(key)") }
        }
    }
}
