import Foundation
import Testing
@testable import Doppelganger

/// L3: a selection resumes as that selection (findings app-orchestration-3,
/// cross-cutting-6), and an attempt is continued at most once per destination
/// (app-orchestration-4). Inverts and tightens the selection-resume repros in
/// Repro_G11_resume_lifecycle.
///
/// No test here calls AppModel.resume, retryFailures, or withdraw: each would
/// build a non-recovered TransferSession, which writes a journal into the
/// host's spool. Engine runs use FixtureBuilder temp directories only.
struct ResumeScopeTests {
    private static let selection: Set<String> = ["DCIM/100MEDIA/a.bin", "DCIM/100MEDIA/b.bin"]

    /// Inverts repro_selectionResumeAsBuiltByAppModelIsVetoed and tightens
    /// repro_selectionResumeCarryingPausedScopeCompletes: the request AppModel
    /// now builds carries the reviewed scope and completes exactly it.
    @Test func selectionResumeCompletesExactlyTheSelection() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "selection-destination")
        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [destination],
            folderName: "Day 01", includedRelativePaths: Self.selection
        )
        let reviewed = try #require(preflight.includedRelativePaths)
        let paused = try await Self.runPaused(
            source: source, destination: destination,
            spool: fixtures.root.appendingPathComponent("pause-spool"),
            sourceFingerprint: preflight.sourceFingerprint, includedRelativePaths: reviewed
        )
        try #require(paused.report.status == .paused)
        let manifestURL = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: paused.report.shortID))
        let pausedEvidence = try Data(contentsOf: manifestURL)
        let pausedManifest = try ManifestWriter.decode(pausedEvidence)

        // Exactly what AppModel.resume forwards.
        let scope = try #require(AppModel.resumeScope(
            pausedScope: reviewed, pausedFingerprint: preflight.sourceFingerprint, manifest: pausedManifest))
        #expect(scope.includedRelativePaths == Self.selection)
        #expect(scope.sourceFingerprint == preflight.sourceFingerprint)

        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: source, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("resume-spool"),
            sourceFingerprint: scope.sourceFingerprint, resumeManifest: pausedManifest,
            includedRelativePaths: scope.includedRelativePaths
        )
        #expect(resumed.report.status == .verified)
        #expect(Set(resumed.report.items.map(\.item.relativePath)) == Self.selection)
        for path in Self.selection {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(path))
                == fixtures.bytes(at: source.appendingPathComponent(path)))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("MISC/c.txt").path))
        #expect(try Data(contentsOf: manifestURL) == pausedEvidence) // parent evidence immutable
    }

    /// The body of repro_selectionResumeAsBuiltByAppModelIsVetoed under a new
    /// intent: should a resume ever lose its scope again, the engine's
    /// fingerprint gate still refuses it before any destination write.
    @Test func scopeLessResumeOfASelectionIsRefusedWithoutWidening() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "selection-destination")
        let preflight = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01",
            includedRelativePaths: Self.selection
        )
        let reviewed = try #require(preflight.includedRelativePaths)
        try #require(reviewed == Self.selection)
        let paused = try await Self.runPaused(
            source: source,
            destination: destination,
            spool: fixtures.root.appendingPathComponent("selection-pause-spool"),
            sourceFingerprint: preflight.sourceFingerprint,
            includedRelativePaths: reviewed
        )
        try #require(paused.report.status == .paused)
        let notYetCopied = paused.report.items
            .filter { $0.outcomes[destination]?.isVerified != true }
            .map(\.item.relativePath)
        try #require(!notYetCopied.isEmpty)
        let pausedManifest = try EngineHarness.decodeManifest(at: destination, shortID: paused.report.shortID)
        try #require(pausedManifest.sourceFingerprint == preflight.sourceFingerprint)

        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("selection-resume-spool"),
            sourceFingerprint: pausedManifest.sourceFingerprint,
            resumeManifest: pausedManifest
        )

        #expect(resumed.report.status == .failed)
        #expect(resumed.report.issues.contains("The source plan changed after review; run preflight again."))
        for path in notYetCopied {
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent(path).path))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("MISC/c.txt").path))
    }

    /// Guards the choice not to narrow a whole-source resume to the paused
    /// item list: a clip shot during the pause must still stop the resume.
    @Test func wholeSourceResumeKeepsTheFingerprintGateForNewFiles() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "whole-destination")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        let paused = try await Self.runPaused(
            source: source, destination: destination,
            spool: fixtures.root.appendingPathComponent("whole-pause-spool"),
            sourceFingerprint: fingerprint, includedRelativePaths: nil
        )
        try #require(paused.report.status == .paused)
        let pausedManifest = try EngineHarness.decodeManifest(at: destination, shortID: paused.report.shortID)
        let scope = try #require(AppModel.resumeScope(
            pausedScope: nil, pausedFingerprint: fingerprint, manifest: pausedManifest))
        #expect(scope.includedRelativePaths == nil, "a whole-source resume must not be narrowed to the paused item list")

        // A clip shot onto the card during the pause.
        try Data(repeating: 7, count: 4_096).write(to: source.appendingPathComponent("DCIM/100MEDIA/d.bin"))

        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: source, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("whole-resume-spool"),
            sourceFingerprint: scope.sourceFingerprint, resumeManifest: pausedManifest,
            includedRelativePaths: scope.includedRelativePaths
        )
        #expect(resumed.report.status == .failed)
        #expect(resumed.report.issues.contains("The source plan changed after review; run preflight again."))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("DCIM/100MEDIA/d.bin").path))
    }

    @Test func resumeScopeRefusesWhatItCannotProve() {
        var manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        manifest.sourceFingerprint = "plan-a"
        let planned: Set<String> = ["DCIM/100MEDIA/A001.MP4", "DCIM/100MEDIA/A002.MP4"]

        #expect(AppModel.resumeScope(pausedScope: planned, pausedFingerprint: "plan-a", manifest: manifest)
            == ResumeScope(includedRelativePaths: planned, sourceFingerprint: "plan-a"))
        #expect(AppModel.resumeScope(pausedScope: nil, pausedFingerprint: "plan-a", manifest: manifest)
            == ResumeScope(includedRelativePaths: nil, sourceFingerprint: "plan-a"))
        #expect(AppModel.resumeScope(pausedScope: ["DCIM/100MEDIA/A001.MP4"], pausedFingerprint: "plan-a", manifest: manifest) == nil)
        #expect(AppModel.resumeScope(pausedScope: planned.union(["MISC/extra.txt"]), pausedFingerprint: "plan-a", manifest: manifest) == nil)
        #expect(AppModel.resumeScope(pausedScope: [], pausedFingerprint: "plan-a", manifest: manifest) == nil)
        #expect(AppModel.resumeScope(pausedScope: planned, pausedFingerprint: "plan-b", manifest: manifest) == nil)
        manifest.sourceFingerprint = nil
        #expect(AppModel.resumeScope(pausedScope: nil, pausedFingerprint: nil, manifest: manifest) == nil)
        #expect(AppModel.resumeScope(pausedScope: planned, pausedFingerprint: "plan-a", manifest: manifest)?.sourceFingerprint == "plan-a")
    }

    /// Pauses after the first file reaches its complete-file boundary, the same
    /// way PauseResumeTests does.
    private static func runPaused(
        source: URL,
        destination: URL,
        spool: URL,
        sourceFingerprint: String?,
        includedRelativePaths: Set<String>?
    ) async throws -> EngineHarness.Run {
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        fileSystem.delayWrites(microseconds: 500)
        return try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: spool,
            sourceFingerprint: sourceFingerprint,
            includedRelativePaths: includedRelativePaths,
            chunkSize: 4 * 1024,
            pauseWhen: { event in
                if case .progress(let progress) = event {
                    return progress.copiedBytes > 32 * 1024
                }
                return false
            }
        )
    }
}

struct ResumeJournalScopeTests {
    private static func journal(
        fixtures: FixtureBuilder,
        includedRelativePaths: [String]?
    ) -> TransferJournal {
        TransferJournal(
            id: UUID(),
            label: "Day 01",
            source: fixtures.root.appendingPathComponent("source"),
            destinationBases: [fixtures.root.appendingPathComponent("drive")],
            destinations: [fixtures.root.appendingPathComponent("drive/Day 01")],
            algorithm: .xxh64,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: Date(),
            itemCount: 2,
            totalBytes: 2048,
            status: .running,
            includedRelativePaths: includedRelativePaths
        )
    }

    @Test func journalRecordsTheReviewedScope() throws {
        let fixtures = try FixtureBuilder()
        let store = TransferJournalStore(root: fixtures.root.appendingPathComponent("spool", isDirectory: true))
        store.save(Self.journal(fixtures: fixtures, includedRelativePaths: ["DCIM/b.bin", "DCIM/a.bin"]))

        let recovered = store.recoverInterrupted()

        #expect(recovered.first?.includedRelativePaths.map { Set($0) } == Set(["DCIM/a.bin", "DCIM/b.bin"]))

        // A whole-source journal writes no key, and one without the key — as
        // every journal before it existed — decodes as whole-source.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let whole = try encoder.encode(Self.journal(fixtures: fixtures, includedRelativePaths: nil))
        #expect(!String(decoding: whole, as: UTF8.self).contains("includedRelativePaths"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TransferJournal.self, from: whole).includedRelativePaths == nil)
    }

    @MainActor
    @Test func recoveredAttemptKeepsItsReviewedScope() throws {
        let fixtures = try FixtureBuilder()
        let scoped = TransferSession(interrupted: Self.journal(
            fixtures: fixtures, includedRelativePaths: ["DCIM/a.bin", "DCIM/b.bin"]
        ))
        #expect(scoped.includedRelativePaths == ["DCIM/a.bin", "DCIM/b.bin"])
        let whole = TransferSession(interrupted: Self.journal(fixtures: fixtures, includedRelativePaths: nil))
        #expect(whole.includedRelativePaths == nil)
    }
}

struct AttemptContinuationTests {
    @Test func aLinkedAttemptClosesOnlyTheDestinationsItTookOver() {
        let parent = UUID(), resume = UUID(), repairB = UUID()
        let a = URL(fileURLWithPath: "/Volumes/A/Day 01"), b = URL(fileURLWithPath: "/Volumes/B/Day 01")
        var continuations = AttemptContinuations()
        #expect(continuations.availability(of: parent) == .open)
        continuations.claim([b], of: parent, by: repairB)
        #expect(continuations.availability(of: parent) == .continued([b]))
        continuations.claim([a, b], of: parent, by: resume)
        #expect(continuations.availability(of: parent) == .continued([a, b]))
        continuations.release(child: resume)      // withdrawn before it started
        #expect(continuations.availability(of: parent) == .continued([b]))
        continuations.release(child: repairB)
        #expect(continuations.availability(of: parent) == .open)
        #expect(continuations.availability(of: UUID()) == .open)
    }

    /// A child that took over no destination still closes its parent.
    @Test func anyLinkedAttemptClosesItsParentEvenWithoutDestinations() {
        let parent = UUID()
        var continuations = AttemptContinuations()
        continuations.claim([], of: parent, by: UUID())
        #expect(continuations.availability(of: parent) == .continued([]))
        #expect(continuations.availability(of: parent) != .open)
    }

    @Test func repairsAreOfferedOnlyWhereNoLinkedAttemptExists() {
        let report = ReportFixtures.failedReport()
        let a = ReportFixtures.destinationA, b = ReportFixtures.destinationB
        #expect(AppModel.failedRelativePaths(in: report, at: a) == ["DCIM/100MEDIA/A002.MP4"])
        #expect(AppModel.failedRelativePaths(in: report, at: b) == ["DCIM/100MEDIA/A001.MP4"])
        #expect(AppModel.retryableFailedPairCount(in: report, destinations: [a, b], availability: .open) == 2)
        #expect(AppModel.retryableFailedPairCount(in: report, destinations: [a, b], availability: .continued([b])) == 1)
        #expect(AppModel.retryableFailedPairCount(in: report, destinations: [a, b], availability: .continued([a, b])) == 0)
        #expect(AppModel.repairableDestinations([a, b], availability: .continued([b])) == [a])
        #expect(AppModel.repairableDestinations([a, b], availability: .open) == [a, b])
    }
}

/// An AppModel recovering from a temp spool over an in-memory catalog.
@MainActor
private struct ContinuationHarness {
    private final class MemorySelectionStore: SelectionStore {
        var source: URL?
        var destinations: [URL] = []
        func load() -> (source: URL?, destinations: [URL]) { (source, destinations) }
        func save(source: URL?, destinations: [URL]) {
            self.source = source
            self.destinations = destinations
        }
    }

    let fixtures: FixtureBuilder
    let spool: URL
    private let suiteName = "ResumeLifecycle-\(UUID().uuidString)"

    init() throws {
        fixtures = try FixtureBuilder()
        spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
    }

    func model() throws -> AppModel {
        AppModel(
            selectionStore: MemorySelectionStore(),
            recents: RecentsStore(defaults: UserDefaults(suiteName: suiteName)!),
            productStore: ProductStore(
                database: try ProductDatabase(inMemory: true),
                avatars: AvatarStore(root: fixtures.root.appendingPathComponent("avatars")),
                spoolRoot: nil
            ),
            spoolRoot: spool
        )
    }

    func folder(_ name: String) throws -> URL {
        let url = fixtures.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func journal(
        parent: UUID? = nil,
        kind: TransferAttemptKind = .copy,
        source: URL? = nil,
        startedAt: Date?,
        status: TransferJournal.Status,
        includedRelativePaths: [String]? = nil
    ) -> TransferJournal {
        let id = UUID()
        let base = fixtures.root.appendingPathComponent("drive", isDirectory: true)
        return TransferJournal(
            id: id,
            taskID: parent ?? id,
            parentAttemptID: parent,
            attemptKind: kind,
            label: "20260810_A001",
            source: source ?? fixtures.root.appendingPathComponent("A001", isDirectory: true),
            destinationBases: [base],
            destinations: [base.appendingPathComponent("20260810_A001-\(id.uuidString.prefix(4))", isDirectory: true)],
            algorithm: .xxh64,
            verificationProfile: .standard,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: startedAt,
            itemCount: 2,
            totalBytes: 2048,
            status: status,
            includedRelativePaths: includedRelativePaths
        )
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
struct ContinuationRelaunchTests {
    /// Linked attempts that started in an earlier launch still own their
    /// parent's destinations; one that never started, or a verification, does
    /// not.
    @Test func startedLinkedAttemptsStillCloseTheirParentAfterRelaunch() throws {
        let harness = try ContinuationHarness()
        defer { harness.tearDown() }
        let store = TransferJournalStore(root: harness.spool)
        let resumedParent = UUID(), repairedParent = UUID(), queuedParent = UUID(), verifiedParent = UUID()
        var resumed = harness.journal(parent: resumedParent, kind: .resume, startedAt: Date(), status: .running)
        resumed.recordVerdict(.verified)
        var repaired = harness.journal(parent: repairedParent, kind: .retry, startedAt: Date(), status: .running)
        repaired.recordVerdict(.failed)
        let queued = harness.journal(parent: queuedParent, kind: .resume, startedAt: nil, status: .queued)
        let verification = harness.journal(parent: verifiedParent, kind: .verification, startedAt: Date(), status: .verified)
        for journal in [resumed, repaired, queued, verification] { store.save(journal) }

        let model = try harness.model()

        #expect(model.continuation(of: resumedParent) == .continued(Set(resumed.destinations)))
        #expect(model.continuation(of: repairedParent) == .continued(Set(repaired.destinations)))
        #expect(model.continuation(of: queuedParent) == .open)
        #expect(model.continuation(of: verifiedParent) == .open)
    }
}

@MainActor
struct RetryAsNewOffloadScopeTests {
    /// Retry as New Offload reviews exactly what the attempt was asked to
    /// copy; a stale pick from an earlier draft never carries over.
    @Test func retryAsNewOffloadReviewsTheAttemptsOwnSelection() throws {
        let harness = try ContinuationHarness()
        defer { harness.tearDown() }
        let model = try harness.model()
        let card = try harness.folder("A001")
        let other = try harness.folder("B002")
        model.addDraftSource(other, selecting: ["CLIPS/x.mov"])
        model.addDraftSource(card, selecting: ["stale.mov"])

        model.retryAsNewOffload(TransferSession(interrupted: harness.journal(
            source: card, startedAt: Date(), status: .interrupted,
            includedRelativePaths: ["DCIM/a.mov", "DCIM/b.mov"]
        )))

        #expect(model.draftSources == [card])
        #expect(model.draftSelection(for: card) == ["DCIM/a.mov", "DCIM/b.mov"])
        #expect(model.draftSelection(for: other) == nil)

        model.retryAsNewOffload(TransferSession(interrupted: harness.journal(
            source: card, startedAt: Date(), status: .interrupted
        )))
        #expect(model.draftSelection(for: card) == nil)
    }
}

struct ResumeLifecycleLocalizationTests {
    @Test func continuationTextShipsInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings",
            subdirectory: nil, localization: "zh-Hans"
        ))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for key in [
            "A linked attempt already continues this one. Use that attempt's card instead.",
            "The paused attempt's reviewed file scope cannot be confirmed; it cannot be resumed safely.",
            "Continued in a linked attempt",
            "A resume or repair attempt already continues this one. Use that attempt's card; continuing this one again would collide with the files it published.",
        ] {
            let value = try #require(catalog[key], "zh-Hans is missing \(key)")
            #expect(value != key)
        }
    }
}
