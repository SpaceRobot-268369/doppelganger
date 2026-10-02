import Foundation
import Testing
@testable import Doppelganger

/// Review follow-up to L2/L3 for Retry as New Offload:
/// - lifecycle-regressions-scope-merge-2: a paused card whose Resume is
///   refused for a lost destination record can follow the refusal's advice.
/// - lifecycle-semantics-ui-l10n-5 / lifecycle-regressions-scope-merge-3: a
///   repair card reviews its task's scope, never only its failed subset.
///
/// Cards come back through AppModel's launch recovery from a fixture spool, so
/// no non-recovered TransferSession (and no host-spool journal) is built.
/// Retry as New Offload only fills the draft and opens the page.
@MainActor
struct RetryAsNewOffloadReviewTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    // MARK: - Paused card

    /// The refusal names Retry as New Offload, and the paused card's action
    /// row now carries it: the draft reviews the paused attempt's own scope
    /// on its own drives, and the paused folder stays exactly as it was.
    @Test func aPausedCardWhoseResumeIsRefusedCanRetryAsANewOffload() async throws {
        let selection: Set<String> = ["DCIM/100MEDIA/a.bin", "DCIM/100MEDIA/b.bin"]
        let world = try await PausedAttemptRestoreTests.makeWorld(selection: selection)
        try #require(world.run.report.status == .paused)
        let model = try PausedAttemptRestoreTests.relaunch(world)
        let card = try #require(model.sessions.first)
        try FileManager.default.removeItem(at: world.destination.appendingPathComponent(world.manifestName))
        let destinationBefore = try world.fixtures.digestSnapshot(of: world.destination)
        let refusal = try #require(throws: ResumeRefusal.self) { try model.resumeManifest(for: card) }
        #expect(refusal.message == L10n.format(
            "Resume needs every destination this transfer paused on. Reconnect %@, or use Retry as New Offload.",
            world.destination.lastPathComponent
        ))

        model.retryAsNewOffload(card)

        #expect(model.showingNewOffload)
        #expect(model.draftSources == [world.source])
        #expect(model.draftDestinations == [world.destination])
        #expect(model.draftSelection(for: world.source) == selection)
        #expect(model.sessions.map(\.id) == [card.id])
        #expect(try world.fixtures.digestSnapshot(of: world.destination) == destinationBefore)
    }

    // MARK: - Repair card

    @MainActor
    private struct Spool {
        let fixtures: FixtureBuilder
        let root: URL
        let card: URL

        init() throws {
            fixtures = try FixtureBuilder()
            root = fixtures.root.appendingPathComponent("spool", isDirectory: true)
            card = fixtures.root.appendingPathComponent("A001", isDirectory: true)
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        }

        /// One attempt's journal as TransferSession keeps it.
        @discardableResult
        func save(
            id: UUID = UUID(),
            parent: UUID? = nil,
            kind: TransferAttemptKind,
            status: TransferJournal.Status,
            scope: [String]?
        ) -> UUID {
            let base = fixtures.root.appendingPathComponent("raid", isDirectory: true)
            TransferJournalStore(root: root).save(TransferJournal(
                id: id,
                parentAttemptID: parent,
                attemptKind: kind,
                label: "20260810_A001",
                source: card,
                destinationBases: [base],
                destinations: [base.appendingPathComponent("20260810_A001", isDirectory: true)],
                algorithm: .xxh64,
                verificationProfile: .standard,
                allowSameVolume: true,
                createdAt: Date(),
                startedAt: Date(),
                itemCount: scope?.count ?? 3,
                totalBytes: 4096,
                status: status,
                includedRelativePaths: scope
            ))
            return id
        }

        func relaunch() throws -> AppModel {
            let suiteName = "RetryAsNewOffloadReview-\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
            return AppModel(
                selectionStore: MemorySelectionStore(),
                recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
                productStore: ProductStore(
                    database: try ProductDatabase(inMemory: true),
                    avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                    spoolRoot: nil
                ),
                spoolRoot: root
            )
        }
    }

    private static let reviewed = ["DCIM/a.mov", "DCIM/b.mov", "DCIM/c.mov"]
    private static let failedSubset = ["DCIM/b.mov"]

    /// The repaired attempt is still on the dashboard: its reviewed selection
    /// is what the new offload reviews.
    @Test func aRepairCardReviewsTheSelectionOfTheAttemptItRepairs() throws {
        let spool = try Spool()
        let parent = spool.save(kind: .copy, status: .running, scope: Self.reviewed)
        let repair = spool.save(parent: parent, kind: .retry, status: .running, scope: Self.failedSubset)
        let model = try spool.relaunch()
        let card = try #require(model.sessions.first { $0.id == repair })
        try #require(card.includedRelativePaths == Set(Self.failedSubset))
        try #require(model.sessions.contains { $0.id == parent })

        model.retryAsNewOffload(card)

        #expect(model.draftSelection(for: spool.card) == Set(Self.reviewed))
        #expect(model.reviewedScope(of: card) == Set(Self.reviewed))
    }

    /// Only the journal is left, as after a relaunch where the failed parent
    /// was dismissed: it still names the reviewed scope. A repair of a repair
    /// walks back to the attempt the operator reviewed.
    @Test func aRepairWhoseParentLeftTheDashboardStillReviewsTheTaskScope() throws {
        let spool = try Spool()
        let parent = spool.save(kind: .copy, status: .failed, scope: Self.reviewed)
        let firstRepair = spool.save(parent: parent, kind: .retry, status: .failed, scope: Self.failedSubset)
        let secondRepair = spool.save(parent: firstRepair, kind: .retry, status: .running, scope: Self.failedSubset)
        let model = try spool.relaunch()
        let card = try #require(model.sessions.first { $0.id == secondRepair })
        try #require(model.sessions.map(\.id) == [secondRepair])

        model.retryAsNewOffload(card)

        #expect(model.draftSelection(for: spool.card) == Set(Self.reviewed))
    }

    /// A whole-source task, or one no record is left for, reviews the whole
    /// source again, never the failed subset.
    @Test func aRepairOfAWholeSourceOrUnknownTaskReviewsTheWholeSource() throws {
        let spool = try Spool()
        let wholeParent = spool.save(kind: .copy, status: .failed, scope: nil)
        let wholeRepair = spool.save(parent: wholeParent, kind: .retry, status: .running, scope: Self.failedSubset)
        let orphanRepair = spool.save(parent: UUID(), kind: .retry, status: .running, scope: Self.failedSubset)
        let model = try spool.relaunch()

        for id in [wholeRepair, orphanRepair] {
            let card = try #require(model.sessions.first { $0.id == id })
            model.retryAsNewOffload(card)
            #expect(model.draftSelection(for: spool.card) == nil, "\(id)")
        }
    }

    /// Copy and resume attempts keep their own reviewed scope.
    @Test func aCopyOrResumeCardReviewsItsOwnScope() throws {
        let spool = try Spool()
        let copy = spool.save(kind: .copy, status: .running, scope: Self.reviewed)
        let resume = spool.save(parent: copy, kind: .resume, status: .running, scope: Self.failedSubset)
        let model = try spool.relaunch()

        let copyCard = try #require(model.sessions.first { $0.id == copy })
        let resumeCard = try #require(model.sessions.first { $0.id == resume })
        #expect(model.reviewedScope(of: copyCard) == Set(Self.reviewed))
        #expect(model.reviewedScope(of: resumeCard) == Set(Self.failedSubset))
    }
}
