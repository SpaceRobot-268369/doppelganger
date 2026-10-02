import Foundation
import Testing
@testable import Doppelganger

/// Review follow-up to L1/L2 (lifecycle-semantics-ui-l10n-4): a queued
/// transfer the app quit before starting wrote nothing. The quit alert says
/// it will not run and the catalog closes it as cancelled, so the dashboard
/// does not bring it back as a red interrupted card with a cleanup action.
/// One that started still comes back for review.
///
/// AppModel recovers from a fixture spool over an in-memory catalog.
@MainActor
struct NeverStartedRecoveryTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    private static func journal(fixtures: FixtureBuilder, startedAt: Date?, status: TransferJournal.Status) -> TransferJournal {
        let id = UUID()
        return TransferJournal(
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
            createdAt: Date(),
            startedAt: startedAt,
            itemCount: 0,
            totalBytes: 0,
            status: status
        )
    }

    @Test func aQueuedTransferThatNeverStartedGetsNoCard() throws {
        let fixtures = try FixtureBuilder()
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let database = try ProductDatabase(inMemory: true)
        let operatorProfile = try database.activeProfile()
        let queued = Self.journal(fixtures: fixtures, startedAt: nil, status: .queued)
        let running = Self.journal(fixtures: fixtures, startedAt: Date(), status: .running)
        for journal in [queued, running] {
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
            TransferJournalStore(root: spool).save(journal)
        }
        try database.registerAttempt(
            id: running.id,
            taskID: running.id,
            kind: .copy,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        let suiteName = "NeverStartedRecovery-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let model = AppModel(
            selectionStore: MemorySelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
            productStore: ProductStore(
                database: database,
                avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: spool
        )

        #expect(model.sessions.map(\.id) == [running.id])
        let card = try #require(model.sessions.first)
        #expect(card.isRecovered)
        #expect(card.headline.isProblem)
        // The catalog tells the same story for each.
        let tasks = try database.taskHistory()
        #expect(tasks.first { $0.id == queued.id }?.verdict == .cancelled)
        #expect(tasks.first { $0.id == running.id }?.verdict == .failed)
        #expect(model.quitImpact == QuitImpact())
    }
}
