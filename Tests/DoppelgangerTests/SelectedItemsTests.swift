import Foundation
import Testing
@testable import Doppelganger

/// Transferring a selection: when the operator asks for specific files, those
/// files are what gets copied — never the rest of the folder holding them.
struct SelectedItemsTests {
    private static let card: [FixtureBuilder.FileSpec] = [
        FixtureBuilder.FileSpec("DCIM/100/A001.MOV", size: 4096, seed: 1),
        FixtureBuilder.FileSpec("DCIM/100/A002.MOV", size: 4096, seed: 2),
        FixtureBuilder.FileSpec("DCIM/100/A003.MOV", size: 4096, seed: 3),
        FixtureBuilder.FileSpec("DCIM/CLIPINFO.XML", size: 256, seed: 4),
        FixtureBuilder.FileSpec("MISC/NOTES.TXT", size: 128, seed: 5),
    ]

    @Test func preflightPlansOnlyTheSelectedItems() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01",
            includedRelativePaths: ["DCIM/100/A001.MOV", "MISC/NOTES.TXT"]
        )

        #expect(result.canStart)
        #expect(result.itemCount == 2)
        #expect(result.sourceItemCount == 5)
        #expect(result.includedRelativePaths == ["DCIM/100/A001.MOV", "MISC/NOTES.TXT"])
        #expect(result.totalBytes == 4096 + 128)
        #expect(result.notices.contains { $0.contains("selected") })
    }

    /// Selecting a folder means everything under it, and nothing beside it.
    @Test func selectingAFolderExpandsToItsFilesOnly() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01",
            includedRelativePaths: ["DCIM/100"]
        )

        #expect(result.canStart)
        #expect(result.includedRelativePaths == [
            "DCIM/100/A001.MOV", "DCIM/100/A002.MOV", "DCIM/100/A003.MOV",
        ])
        #expect(!result.items.contains { $0.relativePath == "MISC/NOTES.TXT" })
    }

    @Test func aSelectionThatNoLongerExistsBlocksTheTransfer() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01",
            includedRelativePaths: ["DCIM/100/A001.MOV", "DCIM/100/GONE.MOV"]
        )

        #expect(!result.canStart)
        #expect(result.blockingIssues.contains { $0.contains("GONE.MOV") })
    }

    /// The whole point: the engine writes the selected files and leaves every
    /// other file in the source folder out of the destination entirely.
    @Test func engineCopiesOnlyTheSelectedFiles() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")
        let spool = try fixtures.makeDestination(named: "spool")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: spool,
            includedRelativePaths: ["DCIM/100/A002.MOV", "MISC/NOTES.TXT"]
        )

        #expect(run.report.status == .verified)
        #expect(Set(run.report.items.map(\.item.relativePath)) == [
            "DCIM/100/A002.MOV", "MISC/NOTES.TXT",
        ])

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("DCIM/100/A002.MOV").path))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("MISC/NOTES.TXT").path))
        // Everything the operator did not ask for stays out of the destination.
        for unselected in ["DCIM/100/A001.MOV", "DCIM/100/A003.MOV", "DCIM/CLIPINFO.XML"] {
            #expect(!manager.fileExists(atPath: destination.appendingPathComponent(unselected).path))
        }
    }

    @MainActor
    @Test func draftKeepsSelectionsPerSourceAndCanWidenThemBackToTheWholeFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(
            selectionStore: NoSelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: "Selection-\(UUID().uuidString)")!),
            productStore: ProductStore(
                database: try ProductDatabase(inMemory: true),
                avatars: AvatarStore(root: root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: root.appendingPathComponent("spool", isDirectory: true)
        )
        let card = root.appendingPathComponent("A001", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)

        model.addDraftSource(card, selecting: ["A001.MOV"])
        #expect(model.draftSelection(for: card) == ["A001.MOV"])

        // Dropping more files from the same folder widens the selection.
        model.addDraftSource(card, selecting: ["A002.MOV"])
        #expect(model.draftSelection(for: card) == ["A001.MOV", "A002.MOV"])
        #expect(model.draftSources.count == 1)

        // Dropping the folder itself asks for all of it, and that wins.
        model.addDraftSource(card)
        #expect(model.draftSelection(for: card) == nil)

        model.addDraftSource(card, selecting: ["A003.MOV"])
        #expect(model.draftSelection(for: card) == nil)

        model.removeDraftSource(card)
        #expect(model.draftSelection(for: card) == nil)
        #expect(model.draftSources.isEmpty)
    }

    private final class NoSelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }
}
