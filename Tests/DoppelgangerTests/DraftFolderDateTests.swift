import Foundation
import Testing
@testable import Doppelganger

/// Review follow-up to L4 (lifecycle-semantics-ui-l10n-3): a batch reviewed
/// before midnight still starts after it. Every folder in a draft takes one
/// date, fixed when the primary's name is derived, so a secondary card's
/// reviewed folder never drifts to the next day and greys out Start.
///
/// Synthetic folders under the system temp dir; Start is never called.
@MainActor
struct DraftFolderDateTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    /// The clock the model reads, moved by the test.
    private final class TestClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static func local(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        )))
    }

    private static let clip: [FixtureBuilder.FileSpec] = [
        FixtureBuilder.FileSpec("DCIM/100/CLIP0001.MOV", size: 2048, seed: 1),
    ]

    @Test func aBatchReviewedBeforeMidnightStillMatchesAfterIt() async throws {
        let fixtures = try FixtureBuilder()
        let clock = TestClock(try Self.local(10, 23, 58))
        let suiteName = "DraftFolderDate-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            selectionStore: MemorySelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
            productStore: ProductStore(
                database: try ProductDatabase(inMemory: true),
                avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: fixtures.root.appendingPathComponent("spool", isDirectory: true),
            clock: { clock.now }
        )
        let cards = try ["EOS_DIGITAL", "Untitled", "NO NAME"].map {
            try fixtures.makeCard(named: $0, files: Self.clip)
        }
        let archive = try fixtures.makeDestination(named: "archive")
        for card in cards { model.addDraftSource(card) }
        model.addDraftDestination(archive)

        let names = cards.map { model.draftFolderName(for: $0) }
        #expect(names == ["20260810_A001", "20260810_A002", "20260810_A003"])
        var plans: [TransferPreflight] = []
        for card in cards {
            plans.append(await TransferPreflight.inspect(
                source: card,
                destinationBases: [archive],
                folderName: model.draftFolderName(for: card)
            ))
        }
        try #require(plans.allSatisfy { $0.canStart })

        // The warning is acknowledged at 00:01: nothing renames.
        clock.now = try Self.local(11, 0, 1)
        #expect(cards.map { model.draftFolderName(for: $0) } == names)
        #expect(plans.allSatisfy { model.reviewedFolderNameIsCurrent($0) })

        // Deriving the names again dates every folder together.
        model.refreshDraftFolderName()
        #expect(cards.map { model.draftFolderName(for: $0) }
            == ["20260811_A001", "20260811_A002", "20260811_A003"])
        #expect(plans.allSatisfy { !model.reviewedFolderNameIsCurrent($0) })
    }
}
