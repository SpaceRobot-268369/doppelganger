import Foundation
import Testing
@testable import Doppelganger

/// The New Offload draft's source list and per-source output folder names. The
/// review sheet reads both, and a duplicate folder name would make two sources
/// write into one output directory.
@MainActor
struct OffloadDraftTests {
    /// An AppModel that touches no real spool, catalog, or user defaults.
    private final class MemorySelectionStore: SelectionStore {
        var source: URL?
        var destinations: [URL] = []

        func load() -> (source: URL?, destinations: [URL]) { (source, destinations) }

        func save(source: URL?, destinations: [URL]) {
            self.source = source
            self.destinations = destinations
        }
    }

    @MainActor
    private struct Harness {
        let model: AppModel
        let root: URL
        private let suiteName: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("doppelganger-draft-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suiteName = "OffloadDraft-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            model = AppModel(
                selectionStore: MemorySelectionStore(),
                recents: RecentsStore(defaults: defaults),
                productStore: ProductStore(
                    database: try ProductDatabase(inMemory: true),
                    avatars: AvatarStore(root: root.appendingPathComponent("avatars")),
                    spoolRoot: nil
                ),
                spoolRoot: root.appendingPathComponent("spool", isDirectory: true)
            )
        }

        func folder(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func firstSourceBecomesPrimaryAndDuplicatesAreIgnored() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let cardA = try harness.folder("A001")
        let cardB = try harness.folder("B002")

        model.addDraftSource(cardA)
        model.addDraftSource(cardB)
        model.addDraftSource(cardA)

        #expect(model.draftSource == cardA)
        #expect(model.draftAdditionalSources == [cardB])
        #expect(model.draftSources.count == 2)
        #expect(model.draftName == TransferPreflight.defaultFolderName(for: cardA))
        #expect(model.draftFolderName(for: cardB) == TransferPreflight.defaultFolderName(for: cardB))
    }

    @Test func removingThePrimarySourcePromotesTheNextOneAndRenamesFromIt() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let cardA = try harness.folder("A001")
        let cardB = try harness.folder("B002")

        model.addDraftSource(cardA)
        model.addDraftSource(cardB)
        model.removeDraftSource(cardA)

        #expect(model.draftSource == cardB)
        #expect(model.draftAdditionalSources.isEmpty)
        // The folder name always follows the promoted source's own reel.
        #expect(model.draftName == TransferPreflight.defaultFolderName(for: cardB))
    }

    /// The transfer folder is `YYYYMMDD_REEL`, always — there is no free-form
    /// name to drift away from the convention.
    @Test func theTransferFolderAlwaysFollowsTheDateAndReelConvention() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let card = try harness.folder("100_FUJI")

        // A card whose name is not a reel still gets a reel-shaped default.
        model.addDraftSource(card)
        #expect(model.draftName == "\(TransferPreflight.dateStamp())_A001")

        model.draftCardLabel = "A100"
        #expect(model.draftName == "\(TransferPreflight.dateStamp())_A100")

        // Clearing the reel falls back to the default, never the raw name.
        model.draftCardLabel = "  "
        #expect(model.draftName == "\(TransferPreflight.dateStamp())_A001")
    }

    /// The reel a card already carries is the reel it keeps; only a card that
    /// names no reel takes the A-camera default.
    @Test func theDefaultReelFollowsTheCameraDepartmentConvention() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model

        model.addDraftSource(try harness.folder("C012"))
        #expect(model.draftReelName == "C012")

        model.removeDraftSource(try harness.folder("C012"))
        model.addDraftSource(try harness.folder("Untitled"))
        #expect(model.draftReelName == "A001")
    }

    /// Two unnamed cards must not both default to A001 — that would send two
    /// sources into one output folder.
    @Test func unnamedSourcesInABatchTakeDistinctDefaultReels() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model

        model.addDraftSource(try harness.folder("Untitled"))
        model.addDraftSource(try harness.folder("Untitled 2"))

        #expect(model.draftName == "\(TransferPreflight.dateStamp())_A001")
        #expect(
            model.draftFolderName(for: try harness.folder("Untitled 2"))
                == "\(TransferPreflight.dateStamp())_A002"
        )
        #expect(model.draftFolderNamesAreUnique)
    }

    /// Removing one picked file leaves the rest of the selection alone;
    /// removing the last one drops the source rather than silently widening
    /// the plan back to the whole folder.
    @Test func removingPickedFilesNeverWidensTheSelection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let card = try harness.folder("A001")

        model.addDraftSource(card, selecting: ["a.mov", "b.mov"])
        model.removeDraftSelection("a.mov", from: card)
        #expect(model.draftSelection(for: card) == ["b.mov"])
        #expect(model.draftSources.count == 1)

        model.removeDraftSelection("b.mov", from: card)
        #expect(model.draftSelection(for: card) == nil)
        #expect(model.draftSources.isEmpty)
    }

    /// A secondary page sits over the detail area, so choosing a sidebar
    /// section has to dismiss it — otherwise the click looks broken.
    @Test func choosingASectionLeavesTheNewOffloadPage() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model

        model.beginOffload()
        #expect(model.showingNewOffload)

        model.selectSection(.manifests)
        #expect(!model.showingNewOffload)
        #expect(model.section == .manifests)

        // Even re-choosing the section the page opened over goes back to it.
        model.beginOffload()
        model.selectSection(.transfers)
        #expect(!model.showingNewOffload)
        #expect(model.section == .transfers)
    }

    @Test func twoSourcesResolvingToOneFolderNameBlockTheReview() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let cardA = try harness.folder("A001")
        let cardB = try harness.folder("B002")

        model.addDraftSource(cardA)
        model.addDraftSource(cardB)
        #expect(model.draftFolderNamesAreUnique)

        // Naming the primary reel after the other source collides.
        model.draftCardLabel = "B002"
        #expect(!model.draftFolderNamesAreUnique)

        // Writing straight into the destination has no per-task folder at all.
        model.draftDestinationLayout = .directly
        #expect(model.draftFolderNamesAreUnique)
    }

    @Test func startingAnOffloadIsRefusedWhileASourceIsMissing() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let card = try harness.folder("A001")
        let destination = try harness.folder("archive")

        model.addDraftSource(card)
        model.addDraftDestination(destination)
        #expect(model.canStartDraft)

        try FileManager.default.removeItem(at: card)
        #expect(!model.canStartDraft)
        #expect(model.draftValidationMessage?.contains("A001") == true)
    }
}
