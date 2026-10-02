import Foundation
import Testing
@testable import Doppelganger

/// A batch of Directly-in-destination sources lands side by side in each
/// destination, so two cards holding the same relative path would collide
/// there and fail one copy mid-offload (engine-semantics-ui-l10n-1). The
/// New Offload page never offers Start for such a reviewed batch, and Start
/// refuses it anyway, naming the shared paths.
///
/// Synthetic fixtures only, all under the system temp dir. Every Start call
/// here runs on a reviewed plan made stale first, so even a broken collision
/// check ends at the reviewed-folder refusal: no TransferSession (and so no
/// journal) can ever be built. The refusal each test expects tells the two
/// apart.
@MainActor
struct DirectBatchCollisionTests {
    private final class MemorySelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    @MainActor
    private struct Harness {
        let model: AppModel
        let fixtures: FixtureBuilder
        private let suiteName: String

        init() throws {
            fixtures = try FixtureBuilder()
            suiteName = "DirectBatchCollision-\(UUID().uuidString)"
            model = AppModel(
                selectionStore: MemorySelectionStore(),
                recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
                productStore: ProductStore(
                    database: try ProductDatabase(inMemory: true),
                    avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                    spoolRoot: nil
                ),
                spoolRoot: fixtures.root.appendingPathComponent("spool", isDirectory: true)
            )
        }

        /// Adds the cards and one destination to the draft and reviews every
        /// card the way the New Offload page does.
        func review(
            _ cards: [URL],
            into destination: URL,
            layout: DestinationLayout
        ) async -> [TransferPreflight] {
            for card in cards { model.addDraftSource(card) }
            model.addDraftDestination(destination)
            model.draftDestinationLayout = layout
            var plans: [TransferPreflight] = []
            for source in model.draftSources {
                plans.append(await TransferPreflight.inspect(
                    source: source,
                    destinationBases: model.draftDestinations,
                    folderName: model.draftFolderName(for: source),
                    layout: layout,
                    includedRelativePaths: model.draftSelection(for: source)
                ))
            }
            return plans
        }

        /// Renames the primary's folder after review. Start then always has a
        /// refusal left after the collision check, so it never builds a session.
        func staleThePrimaryPlan(_ plans: [TransferPreflight]) throws {
            model.draftCardLabel = "A009"
            try #require(!model.reviewedFolderNameIsCurrent(plans[0]))
        }

        func start(_ plans: [TransferPreflight]) {
            model.productStore.clearError()
            model.startDraftOffloads(autoShowLog: false, preflights: plans, warningsAcknowledged: true)
        }

        func tearDown() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    private static let collisionKey =
        "Sources in this batch would write the same files into one destination: %@. Choose New folder under Output so each source gets its own folder."
    private static let staleKey =
        "The folder name for %@ changed after preflight. Run preflight again."

    private static func clip(_ path: String, seed: UInt64) -> FixtureBuilder.FileSpec {
        FixtureBuilder.FileSpec(path, size: 2048, seed: seed)
    }

    /// A reviewed plan built in memory, for comparisons a real disk cannot
    /// pin down (case sensitivity, many shared paths).
    private static func plan(
        _ source: String,
        _ paths: [String],
        into bases: [URL],
        caseSensitive: Bool? = true,
        layout: DestinationLayout = .directly
    ) -> TransferPreflight {
        let items = paths.map { SourceItem(relativePath: $0, size: 2048) }
        let volume = FileSystemVolume(
            identifier: "archive-volume",
            name: "Archive",
            mountPath: "/Volumes/Archive",
            supportsCaseSensitiveNames: caseSensitive
        )
        let folderName = "20261002_\(source)"
        return TransferPreflight(
            source: URL(fileURLWithPath: "/Volumes/\(source)", isDirectory: true),
            folderName: folderName,
            layout: layout,
            includedRelativePaths: nil,
            items: items,
            itemCount: items.count,
            totalBytes: Int64(items.count) * 2048,
            sourceItemCount: items.count,
            sourceFingerprint: TransferPreflight.planFingerprint(items),
            mediaAnalysis: MediaAnalysisSummary(
                detectedFormats: [], mediaFileCount: 0, sidecarFileCount: 0, clips: [], findings: []
            ),
            zeroBytePaths: [],
            sourceVolume: nil,
            sourceMHLStatus: .absent,
            destinations: bases.map { base in
                TransferPreflight.Destination(
                    base: base,
                    output: layout == .directly ? base : base.appendingPathComponent(folderName, isDirectory: true),
                    volume: volume,
                    availableBytes: nil,
                    duplicateManifest: nil
                )
            },
            blockingIssues: [],
            warnings: [],
            notices: []
        )
    }

    // MARK: - Start

    /// Two cards that both hold DCIM/100/C0001.MP4, written directly into one
    /// destination: each plan passes on its own, the batch is refused, and
    /// nothing reaches the destination.
    @Test func twoCardsHoldingTheSameClipAreRefusedIntoOneDirectDestination() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let fixtures = harness.fixtures
        let cardA = try fixtures.makeCard(named: "A001", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 1),
        ])
        let cardB = try fixtures.makeCard(named: "B002", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 2),
            Self.clip("DCIM/100/C0002.MP4", seed: 3),
        ])
        let archive = try fixtures.makeDestination(named: "archive")

        let plans = await harness.review([cardA, cardB], into: archive, layout: .directly)
        try #require(plans.count == 2 && plans.allSatisfy(\.canStart))
        #expect(plans.allSatisfy { harness.model.reviewedFolderNameIsCurrent($0) })

        #expect(AppModel.directLayoutSharedPaths(in: plans) == ["DCIM/100/C0001.MP4"])
        let refusal = try #require(AppModel.directLayoutCollisionMessage(for: plans))
        #expect(refusal == L10n.format(Self.collisionKey, "DCIM/100/C0001.MP4"))

        try harness.staleThePrimaryPlan(plans)
        harness.start(plans)
        #expect(harness.model.sessions.isEmpty)
        #expect(harness.model.productStore.lastError == refusal)
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).isEmpty)
    }

    /// The same file name in another folder, or another file in the same
    /// folder, lands on a distinct path: the batch passes this check and Start
    /// goes on to the next one.
    @Test func distinctPathsIntoOneDirectDestinationAreAllowed() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let fixtures = harness.fixtures
        let cardA = try fixtures.makeCard(named: "A001", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 1),
        ])
        let cardB = try fixtures.makeCard(named: "B002", files: [
            Self.clip("DCIM/101/C0001.MP4", seed: 2),
            Self.clip("DCIM/100/C0002.MP4", seed: 3),
        ])
        let archive = try fixtures.makeDestination(named: "archive")

        let plans = await harness.review([cardA, cardB], into: archive, layout: .directly)
        try #require(plans.count == 2 && plans.allSatisfy(\.canStart))

        #expect(AppModel.directLayoutSharedPaths(in: plans).isEmpty)
        #expect(AppModel.directLayoutCollisionMessage(for: plans) == nil)

        try harness.staleThePrimaryPlan(plans)
        harness.start(plans)
        #expect(harness.model.sessions.isEmpty)
        #expect(harness.model.productStore.lastError == L10n.format(Self.staleKey, cardA.lastPathComponent))
    }

    /// A New-folder batch gives each card its own folder, so two cards holding
    /// the same clip never meet.
    @Test func aNewFolderBatchOfTheSameClipIsUnaffected() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let fixtures = harness.fixtures
        let cardA = try fixtures.makeCard(named: "A001", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 1),
        ])
        let cardB = try fixtures.makeCard(named: "B002", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 2),
        ])
        let archive = try fixtures.makeDestination(named: "archive")

        let plans = await harness.review([cardA, cardB], into: archive, layout: .newFolder)
        try #require(plans.count == 2 && plans.allSatisfy(\.canStart))
        #expect(Set(plans.flatMap { $0.destinations.map(\.output) }).count == 2)

        #expect(AppModel.directLayoutSharedPaths(in: plans).isEmpty)
        #expect(AppModel.directLayoutCollisionMessage(for: plans) == nil)

        try harness.staleThePrimaryPlan(plans)
        harness.start(plans)
        #expect(harness.model.sessions.isEmpty)
        #expect(harness.model.productStore.lastError == L10n.format(Self.staleKey, cardA.lastPathComponent))
    }

    // MARK: - New Offload page

    /// Start on the New Offload page is offered only for a batch Start would
    /// take. Two cards sharing a clip pass every per-plan check, so the shared
    /// path alone has to keep the button disabled, before any click.
    @Test func theStartButtonStaysDisabledForADirectBatchSharingAPath() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let fixtures = harness.fixtures
        let cardA = try fixtures.makeCard(named: "A001", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 1),
        ])
        let cardB = try fixtures.makeCard(named: "B002", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 2),
        ])
        let archive = try fixtures.makeDestination(named: "archive")

        let plans = await harness.review([cardA, cardB], into: archive, layout: .directly)
        try #require(plans.count == 2 && plans.allSatisfy(\.canStart))
        let collision = try #require(AppModel.directLayoutCollisionMessage(for: plans))

        // Every other check passes: without the collision, Start would be offered.
        #expect(NewOffloadPage.reviewedBatchCanStart(
            plans, model: harness.model, warningsAcknowledged: true, directLayoutCollision: nil
        ))
        #expect(!NewOffloadPage.reviewedBatchCanStart(
            plans, model: harness.model, warningsAcknowledged: true, directLayoutCollision: collision
        ))
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).isEmpty)
    }

    /// Distinct paths leave Start available; the checks the button already
    /// made (a folder renamed after review, no plans at all) still disable it.
    @Test func theStartButtonIsOfferedForADirectBatchOfDistinctPaths() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let fixtures = harness.fixtures
        let cardA = try fixtures.makeCard(named: "A001", files: [
            Self.clip("DCIM/100/C0001.MP4", seed: 1),
        ])
        let cardB = try fixtures.makeCard(named: "B002", files: [
            Self.clip("DCIM/101/C0001.MP4", seed: 2),
        ])
        let archive = try fixtures.makeDestination(named: "archive")

        let plans = await harness.review([cardA, cardB], into: archive, layout: .directly)
        try #require(plans.count == 2 && plans.allSatisfy(\.canStart))
        let collision = AppModel.directLayoutCollisionMessage(for: plans)
        #expect(collision == nil)

        #expect(NewOffloadPage.reviewedBatchCanStart(
            plans, model: harness.model, warningsAcknowledged: true, directLayoutCollision: collision
        ))
        #expect(!NewOffloadPage.reviewedBatchCanStart(
            [], model: harness.model, warningsAcknowledged: true, directLayoutCollision: nil
        ))
        try harness.staleThePrimaryPlan(plans)
        #expect(!NewOffloadPage.reviewedBatchCanStart(
            plans, model: harness.model, warningsAcknowledged: true, directLayoutCollision: collision
        ))
    }

    // MARK: - Comparison

    /// A case-insensitive volume (and one whose case handling is unknown)
    /// stores DCIM/100/C0001.MP4 and dcim/100/c0001.mp4 as one file; only a
    /// volume known to be case-sensitive keeps them apart.
    @Test(arguments: [false, nil, true] as [Bool?])
    func pathsDifferingOnlyInCaseCollideUnlessTheVolumeIsCaseSensitive(caseSensitive: Bool?) throws {
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let archive = try fixtures.makeDestination(named: "archive")
        let plans = [
            Self.plan("A001", ["DCIM/100/C0001.MP4"], into: [archive], caseSensitive: caseSensitive),
            Self.plan("B002", ["dcim/100/c0001.mp4"], into: [archive], caseSensitive: caseSensitive),
        ]

        let expected: [String] = caseSensitive == true ? [] : ["DCIM/100/C0001.MP4"]
        #expect(AppModel.directLayoutSharedPaths(in: plans) == expected)
    }

    /// One name typed precomposed on one card and decomposed on another is one
    /// file on a macOS volume, even a case-sensitive one.
    @Test func canonicallyEquivalentSpellingsCollide() throws {
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let archive = try fixtures.makeDestination(named: "archive")
        let plans = [
            Self.plan("A001", ["Caf\u{E9}/C0001.MP4"], into: [archive]),
            Self.plan("B002", ["Cafe\u{301}/C0001.MP4"], into: [archive]),
        ]

        #expect(AppModel.directLayoutSharedPaths(in: plans) == ["Caf\u{E9}/C0001.MP4"])
    }

    /// Destinations are compared by canonical base: one folder reached through
    /// a symlink is the same destination, while two separate folders are not.
    @Test func destinationsAreComparedByCanonicalBase() throws {
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let archive = try fixtures.makeDestination(named: "archive")
        let other = try fixtures.makeDestination(named: "other")
        let link = fixtures.root.appendingPathComponent("archive-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        let clip = ["DCIM/100/C0001.MP4"]

        let throughLink = [
            Self.plan("A001", clip, into: [archive]),
            Self.plan("B002", clip, into: [link]),
        ]
        #expect(AppModel.directLayoutSharedPaths(in: throughLink) == clip)

        let separate = [
            Self.plan("A001", clip, into: [archive]),
            Self.plan("B002", clip, into: [other]),
        ]
        #expect(AppModel.directLayoutSharedPaths(in: separate).isEmpty)
    }

    /// Any two sources of a larger batch can collide; one card's own paths
    /// never collide with each other here (preflight reports those itself).
    @Test func onlyPathsSharedAcrossSourcesAreReported() throws {
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let archive = try fixtures.makeDestination(named: "archive")

        let batch = [
            Self.plan("A001", ["DCIM/100/C0001.MP4"], into: [archive]),
            Self.plan("B002", ["DCIM/100/C0002.MP4"], into: [archive]),
            Self.plan("C003", ["DCIM/100/C0001.MP4"], into: [archive]),
        ]
        #expect(AppModel.directLayoutSharedPaths(in: batch) == ["DCIM/100/C0001.MP4"])

        let ownCaseTwins = [
            Self.plan("A001", ["DCIM/100/C0001.MP4", "DCIM/100/c0001.mp4"], into: [archive], caseSensitive: false),
            Self.plan("B002", ["DCIM/100/C0002.MP4"], into: [archive], caseSensitive: false),
        ]
        #expect(AppModel.directLayoutSharedPaths(in: ownCaseTwins).isEmpty)
    }

    /// The refusal names the first three shared paths in order and points at
    /// the New folder layout; New-folder plans are never compared.
    @Test func theRefusalNamesAtMostThreeSharedPaths() throws {
        let fixtures = try FixtureBuilder()
        defer { withExtendedLifetime(fixtures) {} }
        let archive = try fixtures.makeDestination(named: "archive")
        let clips = ["DCIM/100/C0004.MP4", "DCIM/100/C0002.MP4", "DCIM/100/C0001.MP4", "DCIM/100/C0003.MP4"]
        let plans = [
            Self.plan("A001", clips, into: [archive]),
            Self.plan("B002", clips.reversed(), into: [archive]),
        ]

        let refusal = try #require(AppModel.directLayoutCollisionMessage(for: plans))
        #expect(refusal == L10n.format(
            Self.collisionKey,
            "DCIM/100/C0001.MP4, DCIM/100/C0002.MP4, DCIM/100/C0003.MP4"
        ))
        #expect(!refusal.contains("C0004"))

        let newFolder = [
            Self.plan("A001", clips, into: [archive], layout: .newFolder),
            Self.plan("B002", clips, into: [archive], layout: .newFolder),
        ]
        #expect(AppModel.directLayoutCollisionMessage(for: newFolder) == nil)
    }

    @Test func theRefusalShipsInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings",
            subdirectory: nil, localization: "zh-Hans"
        ))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let value = try #require(catalog[Self.collisionKey], "zh-Hans is missing the direct-batch refusal")
        #expect(value != Self.collisionKey)
        #expect(value.contains("%@"))
    }
}
