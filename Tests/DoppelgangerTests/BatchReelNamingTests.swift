import Foundation
import Testing
@testable import Doppelganger

/// L4: batch reel naming and the reviewed-folder check at Start (findings
/// ui-new-offload-3, app-orchestration-17, ui-new-offload-2). Ports
/// Repro_G12_preflight_batch.repro_batchReelCollision.
///
/// Synthetic fixtures only, all under the system temp dir. Start is called
/// once, on a refusal path that returns before any TransferSession (and so
/// any journal) exists, and only after the refusal is proven. Never call it
/// here with a plan that could start.
@MainActor
struct BatchReelNamingTests {
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
                .appendingPathComponent("doppelganger-l4-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suiteName = "BatchReelNaming-\(UUID().uuidString)"
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

        /// Selects a project camera whose catalog already holds `reels`.
        @discardableResult
        func selectCamera(prefix: String, offloaded reels: [String]) throws -> CameraRecord {
            let store = model.productStore
            store.createProject(name: "Feature")
            let project = try #require(store.projects.first)
            let camera = try #require(
                store.createCamera(projectID: project.id, reelPrefix: prefix, name: "\(prefix) Camera")
            )
            for reel in reels {
                let id = UUID()
                store.registerTask(
                    id: id,
                    label: "20261001_\(reel)",
                    source: root.appendingPathComponent("prior-\(reel)"),
                    destinations: [root.appendingPathComponent("prior-dest")],
                    projectID: project.id,
                    algorithm: .xxh3,
                    verificationProfile: .standard
                )
                store.updateTaskOrganization(
                    taskID: id,
                    projectID: project.id,
                    shootingDay: "Day 01",
                    cameraLabel: camera.displayName,
                    cardLabel: reel
                )
            }
            model.selectedProjectID = project.id
            model.selectDraftCamera(camera)
            return camera
        }

        func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let clip: [FixtureBuilder.FileSpec] = [
        FixtureBuilder.FileSpec("DCIM/100/CLIP0001.MOV", size: 2048, seed: 1),
    ]

    /// ui-new-offload-3 (port of repro_batchReelCollision). With A001 in
    /// history the A camera suggests A002 for the primary; an unnamed second
    /// card used to default to A002 by position and block the review.
    @Test func aCameraSuggestedReelNeverCollidesWithAnUnnamedSecondCard() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        try harness.selectCamera(prefix: "A", offloaded: ["A001"])
        try #require(model.draftCardLabel == "A002")

        let eos = try harness.folder("EOS_DIGITAL")
        let untitled = try harness.folder("Untitled")
        model.addDraftSource(eos)
        model.addDraftSource(untitled)
        let stamp = TransferPreflight.dateStamp()
        try #require(model.draftName == "\(stamp)_A002")

        #expect(model.draftFolderName(for: eos) == "\(stamp)_A002")
        #expect(model.draftFolderName(for: untitled) == "\(stamp)_A003")
        #expect(model.draftFolderNamesAreUnique)
        #expect(model.draftFolderNameCollision == nil)
    }

    /// app-orchestration-17: camera B is on B004. Three unnamed cards become
    /// B004, B005, B006, not B004, A002, A003.
    @Test func unnamedBatchCardsContinueTheSelectedCamerasRun() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        try harness.selectCamera(prefix: "B", offloaded: ["B001", "B002", "B003"])
        try #require(model.draftCardLabel == "B004")

        let cards = try ["EOS_DIGITAL", "Untitled", "NO NAME"].map { try harness.folder($0) }
        for card in cards { model.addDraftSource(card) }

        let stamp = TransferPreflight.dateStamp()
        #expect(cards.map { model.draftFolderName(for: $0) }
            == ["B004", "B005", "B006"].map { "\(stamp)_\($0)" })
        #expect(model.draftFolderNamesAreUnique)
    }

    /// A card that carries its own reel keeps it, and an unnamed card skips
    /// that reel rather than defaulting onto it.
    @Test func aCardCarryingItsOwnReelKeepsItAndTheRunSkipsIt() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let cards = try ["Untitled", "Untitled 2", "A002"].map { try harness.folder($0) }
        for card in cards { model.addDraftSource(card) }

        let stamp = TransferPreflight.dateStamp()
        #expect(cards.map { model.draftFolderName(for: $0) }
            == ["A001", "A003", "A002"].map { "\(stamp)_\($0)" })
        #expect(model.draftFolderNamesAreUnique)
    }

    /// app-orchestration-17 / ui-new-offload-3: each task is catalogued with
    /// the reel its own folder is named after, and with none when no reel was
    /// entered, which is what a single source has always recorded.
    @Test func eachBatchTaskIsCataloguedWithItsOwnReel() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        try harness.selectCamera(prefix: "B", offloaded: ["B001", "B002", "B003"])
        let cards = try ["EOS_DIGITAL", "Untitled", "NO NAME"].map { try harness.folder($0) }
        for card in cards { model.addDraftSource(card) }

        #expect(cards.map { model.draftCatalogReel(for: $0) } == ["B004", "B005", "B006"])

        model.draftCardLabel = ""
        #expect(cards.map { model.draftCatalogReel(for: $0) } == ["", "", ""])
    }

    /// The one collision a batch can still have, an entered reel equal to a
    /// card's own reel, names the shared folder so the footer can say what
    /// to change.
    @Test func aBatchCollisionNamesTheSharedFolder() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        model.addDraftSource(try harness.folder("A001"))
        model.addDraftSource(try harness.folder("B002"))
        #expect(model.draftFolderNameCollision == nil)

        model.draftCardLabel = "B002"
        #expect(!model.draftFolderNamesAreUnique)
        #expect(model.draftFolderNameCollision == "\(TransferPreflight.dateStamp())_B002")

        model.draftDestinationLayout = .directly
        #expect(model.draftFolderNameCollision == nil)
    }

    /// ui-new-offload-2: a preflight that finished after a Reel Name edit
    /// describes the old folder. It must not read as current, and Start must
    /// refuse it with a reason, create no session and write nothing.
    @Test func aPreflightReviewedUnderAnEarlierReelCannotStart() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let card = try fixtures.makeCard(named: "Untitled", files: Self.clip)
        let archive = try fixtures.makeDestination(named: "archive")
        model.addDraftSource(card)
        model.addDraftDestination(archive)

        // The scan captures the folder name when it starts…
        let preflight = await TransferPreflight.inspect(
            source: card,
            destinationBases: [archive],
            folderName: model.draftFolderName(for: card)
        )
        try #require(preflight.canStart)
        #expect(model.reviewedFolderNameIsCurrent(preflight))

        // …and the operator types a new reel before it finishes.
        model.draftCardLabel = "A002"
        try #require(model.draftName == "\(TransferPreflight.dateStamp())_A002")
        // Stop before Start if the check itself is broken: Start with a plan
        // that passes would build a real session.
        try #require(!model.reviewedFolderNameIsCurrent(preflight))

        model.productStore.clearError()
        model.startDraftOffloads(autoShowLog: false, preflights: [preflight], warningsAcknowledged: true)
        #expect(model.sessions.isEmpty)
        #expect(model.productStore.lastError == L10n.format(
            "The folder name for %@ changed after preflight. Run preflight again.",
            card.lastPathComponent
        ))
        #expect(!FileManager.default.fileExists(
            atPath: archive.appendingPathComponent(preflight.folderName).path
        ))
    }

    /// ui-new-offload-2, batch case: the primary's reel now leads every
    /// unnamed card's folder, so one Reel Name edit stales every reviewed
    /// plan, and a plan for a source that left the draft never reads as current.
    @Test func aReelEditStalesEveryReviewedPlanInABatch() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let model = harness.model
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let eos = try fixtures.makeCard(named: "EOS_DIGITAL", files: Self.clip)
        let untitled = try fixtures.makeCard(named: "Untitled", files: Self.clip)
        let archive = try fixtures.makeDestination(named: "archive")
        model.addDraftSource(eos)
        model.addDraftSource(untitled)
        model.addDraftDestination(archive)

        var plans: [TransferPreflight] = []
        for source in model.draftSources {
            plans.append(await TransferPreflight.inspect(
                source: source,
                destinationBases: [archive],
                folderName: model.draftFolderName(for: source)
            ))
        }
        let stamp = TransferPreflight.dateStamp()
        #expect(plans.map(\.folderName) == ["\(stamp)_A001", "\(stamp)_A002"])
        #expect(plans.allSatisfy { model.reviewedFolderNameIsCurrent($0) })

        model.draftCardLabel = "B001"
        #expect(model.draftFolderName(for: untitled) == "\(stamp)_B002")
        #expect(plans.allSatisfy { !model.reviewedFolderNameIsCurrent($0) })

        model.removeDraftSource(untitled)
        #expect(model.draftFolderName(for: untitled).isEmpty)
        #expect(!model.reviewedFolderNameIsCurrent(plans[1]))
    }

    @Test func newBatchStringsShipInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings",
            subdirectory: nil, localization: "zh-Hans"
        ))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for key in [
            "The folder name for %@ changed after preflight. Run preflight again.",
            "Two sources would write to %@. Change the Reel Name or remove a source.",
        ] {
            let value = try #require(catalog[key], "zh-Hans is missing \(key)")
            #expect(value != key)
            #expect(value.contains("%@"))
        }
    }
}
