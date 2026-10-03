import Darwin
import Foundation
import Testing
@testable import Doppelganger

/// Preflight, the engine plan and the post-transfer rescan all share
/// `RealFileSystem.enumerate(root:)` and treat its result as the complete
/// source. A folder that cannot be listed (EACCES/EPERM here; EIO on a failing
/// card) must therefore fail the scan and be named, never silently shrink the
/// plan into a self-consistent, green transfer.
///
/// Synthetic fixtures only, in a per-test temp dir (Principle 3). An
/// "unreadable folder" is a scratch directory chmod'ed to 000; every test
/// registers the restoring `defer` before it locks anything, so FixtureBuilder
/// can always remove the tree. Root ignores mode bits, so each lock is checked
/// with a precondition `#require`.
struct SourceEnumerationIntegrityTests {
    private let fs = RealFileSystem()

    private static let cardFiles: [FixtureBuilder.FileSpec] = [
        .init("DCIM/100MEDIA/A001.MP4", size: 120_000, seed: 1),
        .init("DCIM/101MEDIA/B001.MP4", size: 90_000, seed: 2),
        .init("DCIM/101MEDIA/B002.MP4", size: 70_000, seed: 3),
    ]

    private static func lock(_ directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    }

    private static func unlock(_ directory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    /// Confirms the fixture really is unreadable for this process, so a pass
    /// or failure below is about doppelganger and not the environment.
    private static func requireUnreadable(_ directory: URL) throws {
        try #require(geteuid() != 0, "permission fixture is meaningless when running as root")
        try #require(
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == nil,
            "fixture directory should be unreadable after chmod 000"
        )
    }

    // MARK: - Enumeration

    /// An unreadable directory under the source root is a typed failure that
    /// names the folder, not a silently truncated plan.
    @Test func unreadableSubdirectoryFailsTheScanAndNamesTheFolder() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.cardFiles)
        let locked = card.appendingPathComponent("DCIM/101MEDIA", isDirectory: true)

        // Control: with everything readable, all three clips are planned.
        #expect(try fs.enumerate(root: card).count == 3)

        defer {
            Self.unlock(locked)
            withExtendedLifetime(fixtures) {}
        }
        try Self.lock(locked)
        try Self.requireUnreadable(locked)

        let error = #expect(throws: FileSystemError.self) { try fs.enumerate(root: card) }
        guard case .notReadable(let detail)? = error else {
            Issue.record("expected .notReadable, got \(String(describing: error))")
            return
        }
        #expect(detail.contains("DCIM/101MEDIA"), "detail must name the unreadable folder: \(detail)")
        #expect(!detail.contains("100MEDIA"), "a readable folder must not be reported: \(detail)")

        // Unlocking restores the full plan, so the lock alone caused the failure.
        Self.unlock(locked)
        #expect(try fs.enumerate(root: card).count == 3)
    }

    /// A source root the process cannot list (permissions/TCC) used to come
    /// back as `[]` and read as "The source is empty."
    @Test func unreadableRootIsNotReportedAsAnEmptySource() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(named: "LOCKED_ROOT_CARD", files: Self.cardFiles)

        #expect(try fs.enumerate(root: card).count == 3)

        defer {
            Self.unlock(card)
            withExtendedLifetime(fixtures) {}
        }
        try Self.lock(card)
        try Self.requireUnreadable(card)

        let error = #expect(throws: FileSystemError.self) { try fs.enumerate(root: card) }
        guard case .notReadable(let detail)? = error else {
            Issue.record("expected .notReadable (not .volumeGone or an empty plan), got \(String(describing: error))")
            return
        }
        #expect(detail.contains(card.lastPathComponent), "detail must name the unreadable root: \(detail)")

        Self.unlock(card)
        #expect(try fs.enumerate(root: card).count == 3)
    }

    /// macOS keeps several metadata folders unreadable on real volume roots.
    /// They are excluded from every plan anyway, so a read error there leaves
    /// no gap and must not block every card.
    @Test func unreadableOperatingSystemMetadataIsNotAGapInThePlan() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("DCIM/100MEDIA/A001.MP4", size: 120_000, seed: 1),
            .init(".Trashes/501/deleted.MP4", size: 4_096, seed: 11),
            .init(".Spotlight-V100/Store-V2/store.db", size: 2_048, seed: 12),
            .init(".fseventsd/0000000000000001", size: 512, seed: 13),
        ])
        let metadataFolders = [".Trashes", ".Spotlight-V100", ".fseventsd"].map {
            card.appendingPathComponent($0, isDirectory: true)
        }

        defer {
            for folder in metadataFolders { Self.unlock(folder) }
            withExtendedLifetime(fixtures) {}
        }
        for folder in metadataFolders {
            try Self.lock(folder)
            try Self.requireUnreadable(folder)
        }

        let planned = try fs.enumerate(root: card).map(\.relativePath)
        #expect(planned == ["DCIM/100MEDIA/A001.MP4"])
    }

    /// The root-level macOS-private stores are tolerated exactly where macOS
    /// puts them. The same name deeper in the tree is ordinary content, and an
    /// unreadable lookalike fails the scan.
    @Test func rootLevelSystemStoresAreToleratedOnlyAtTheRoot() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("DCIM/100MEDIA/A001.MP4", size: 120_000, seed: 1),
            .init(".DocumentRevisions-V100/PerUID/rev.db", size: 1_024, seed: 21),
            .init("DCIM/.DocumentRevisions-V100/B001.MP4", size: 90_000, seed: 2),
        ])
        let rootStore = card.appendingPathComponent(".DocumentRevisions-V100", isDirectory: true)
        let nestedLookalike = card.appendingPathComponent("DCIM/.DocumentRevisions-V100", isDirectory: true)

        defer {
            Self.unlock(nestedLookalike)
            Self.unlock(rootStore)
            withExtendedLifetime(fixtures) {}
        }
        try Self.lock(rootStore)
        try Self.requireUnreadable(rootStore)

        #expect(try fs.enumerate(root: card).map(\.relativePath) == [
            "DCIM/.DocumentRevisions-V100/B001.MP4",
            "DCIM/100MEDIA/A001.MP4",
        ])

        try Self.lock(nestedLookalike)
        try Self.requireUnreadable(nestedLookalike)

        let error = #expect(throws: FileSystemError.self) { try fs.enumerate(root: card) }
        guard case .notReadable(let detail)? = error else {
            Issue.record("expected .notReadable, got \(String(describing: error))")
            return
        }
        #expect(
            detail.contains("DCIM/.DocumentRevisions-V100"),
            "detail must name the nested lookalike: \(detail)"
        )
    }

    // MARK: - Engine

    /// End to end: no profile may report anything but Failed when part of the
    /// source tree could not be read, and nothing is published or touched.
    @Test(arguments: VerificationProfile.allCases)
    func engineFailsWithoutCopyingWhenASourceSubdirectoryIsUnreadable(profile: VerificationProfile) async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.cardFiles)
        let destination = try fixtures.makeDestination(named: "dest")
        let locked = card.appendingPathComponent("DCIM/101MEDIA", isDirectory: true)
        let sourceBefore = try fixtures.digestSnapshot(of: card)
        try #require(sourceBefore.count == 3)

        defer {
            Self.unlock(locked)
            withExtendedLifetime(fixtures) {}
        }
        try Self.lock(locked)
        try Self.requireUnreadable(locked)

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"),
            verificationProfile: profile
        )

        #expect(
            run.report.status == .failed,
            "\(profile) transfer reported \(run.report.status) although DCIM/101MEDIA (2 clips) was never read"
        )
        #expect(run.report.items.isEmpty)
        #expect(run.report.verifiedCount == 0)
        #expect(
            run.report.issues.contains { $0.contains("DCIM/101MEDIA") },
            "the report must name the unreadable folder: \(run.report.issues)"
        )
        // Not even the readable A001 is published from a partial plan.
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("DCIM").path))

        // The source is untouched (read after unlocking, so the snapshot is complete).
        Self.unlock(locked)
        #expect(try fixtures.digestSnapshot(of: card) == sourceBefore)
    }

    // MARK: - Preflight

    /// Preflight blocks rather than showing a smaller, clean-looking plan, and
    /// names the folder instead of calling the source empty.
    @Test func preflightBlocksAndOffersNoPartialPlanWhenASourceSubdirectoryIsUnreadable() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.cardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let locked = card.appendingPathComponent("DCIM/101MEDIA", isDirectory: true)

        // Control: the readable card passes preflight in this environment, so
        // any block below is caused by the unreadable folder.
        let control = await TransferPreflight.inspect(
            source: card, destinationBases: [destination], folderName: "Day 01")
        try #require(control.canStart, "environment precondition: \(control.blockingIssues)")
        #expect(control.itemCount == 3)

        defer {
            Self.unlock(locked)
            withExtendedLifetime(fixtures) {}
        }
        try Self.lock(locked)
        try Self.requireUnreadable(locked)

        let result = await TransferPreflight.inspect(
            source: card, destinationBases: [destination], folderName: "Day 01")

        #expect(
            !result.canStart,
            "preflight allowed a \(result.itemCount)-file plan with no blocking issue while DCIM/101MEDIA was unreadable"
        )
        #expect(result.items.isEmpty)
        #expect(result.itemCount == 0)
        #expect(
            result.blockingIssues.contains { $0.contains("DCIM/101MEDIA") },
            "a blocking issue must name the unreadable folder: \(result.blockingIssues)"
        )
        #expect(
            !result.blockingIssues.contains { $0.contains("source is empty") },
            "an unreadable source must not be reported as empty: \(result.blockingIssues)"
        )
    }

    // MARK: - Localization

    @Test func incompleteScanBlockerHasASimplifiedChineseTranslation() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(
            bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "zh-Hans"
            )
        )
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let key = "The source could not be read completely: %@"
        let value = try #require(catalog[key], "zh-Hans catalog is missing \(key)")
        #expect(value != key)
        #expect(value.contains("%@"))
    }

    // MARK: - Verify Existing Media

    private final class NoSelectionStore: SelectionStore {
        func load() -> (source: URL?, destinations: [URL]) { (nil, []) }
        func save(source: URL?, destinations: [URL]) {}
    }

    /// Verify Existing Media over a folder with an unreadable subfolder: the
    /// operator gets a message naming the folder, and the catalog attempt the
    /// run registered is finished as failed rather than left "copying".
    @MainActor
    @Test func verifyExistingOverAnUnreadableFolderFailsAndClosesItsAttempt() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: Self.cardFiles)
        let copy = try fixtures.makeDestination(named: "copy")
        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [copy],
            spool: fixtures.root.appendingPathComponent("spool")
        )
        try #require(run.report.status == .verified)
        let reference = copy.appendingPathComponent(ManifestWriter.manifestFileName(shortID: run.report.shortID))

        let suite = "VerifyExistingUnreadable-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(
            selectionStore: NoSelectionStore(),
            recents: RecentsStore(defaults: try #require(UserDefaults(suiteName: suite))),
            productStore: ProductStore(
                database: try ProductDatabase(inMemory: true),
                avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: fixtures.root.appendingPathComponent("app-spool", isDirectory: true)
        )

        let locked = copy.appendingPathComponent("DCIM/101MEDIA")
        defer { Self.unlock(locked); withExtendedLifetime(fixtures) {} }
        try Self.lock(locked)
        try Self.requireUnreadable(locked)

        do {
            _ = try await model.verifyExisting(referenceURL: reference, mediaRoot: copy)
            Issue.record("verification over an unreadable folder must not produce a report")
        } catch let failure as VerifyExistingFailure {
            #expect(failure.message.contains("DCIM/101MEDIA"))
        }

        let task = try #require(model.productStore.taskHistory.first { $0.sourcePath == copy.path })
        #expect(task.verdict == .failed)
        #expect(task.lifecycle == .failed)
    }
}
