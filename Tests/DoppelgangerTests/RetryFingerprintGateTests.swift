import Foundation
import Testing
@testable import Doppelganger

/// The source-plan gate for a fine-grained retry (Repair). `AppModel.retryFailures`
/// hands each repair its parent's fingerprint (`manifest.sourceFingerprint`),
/// which covers the parent's whole reviewed plan, while the repair itself is
/// narrowed to the parent's failed pairs. The engine compares that fingerprint
/// with the current source restricted to the parent's own plan, so a partial
/// repair is not vetoed as a changed source, and a source that really changed
/// since the parent still is.
///
/// The same gate refuses to continue a partial repair, whose manifest records
/// the parent's whole-plan fingerprint over only the files it repaired: a
/// repair of that repair, or a resume of it once paused. Each is refused
/// before any destination is touched, and the refusal names the record, not
/// a source change that never happened.
///
/// Synthetic fixtures only (FixtureBuilder temp dir). `TransferSession` is not
/// constructed because its init writes a journal under Application Support;
/// the requests mirror what `TransferSession.start()` builds instead.
struct RetryFingerprintGateTests {
    private static let folderName = "20261002_A001"
    private static let corruptedPath = "DCIM/100MEDIA/a.bin"
    private static let secondCorruptedPath = "DCIM/100MEDIA/b.bin"

    private static let sourceChanged = "The source plan changed after review; run preflight again."
    private static let retryRecordRefused = "The failed attempt's manifest does not describe the reviewed source plan; "
        + "the retry cannot be checked against it."
    private static let resumeRecordRefused = "The paused attempt's manifest does not describe the source plan being "
        + "resumed; the resume cannot continue it. Use Retry as New Offload instead."

    private static func run(
        _ request: TransferRequest,
        on fileSystem: any FileSystemAccess = RealFileSystem(),
        chunkSize: Int = 64 * 1024,
        pauseWhen: (@Sendable (TransferEvent) -> Bool)? = nil
    ) async throws -> TransferReport {
        let engine = TransferEngine(
            fileSystem: fileSystem,
            configuration: TransferConfiguration(chunkSize: chunkSize, progressInterval: .milliseconds(1))
        )
        var report: TransferReport?
        var pauseSent = false
        for await event in await engine.run(request) {
            if !pauseSent, let pauseWhen, pauseWhen(event) {
                pauseSent = true
                await engine.pause()
            }
            if case .finished(let finished) = event { report = finished }
        }
        return try #require(report, "stream must end with .finished")
    }

    /// Pause timed like PauseResumeTests: the request lands while the first
    /// file is mid-copy, so the copy pass stops after that file.
    private static func runPausingAfterTheFirstFile(_ request: TransferRequest) async throws -> TransferReport {
        let slow = FailpointFileSystem(base: RealFileSystem())
        slow.delayReads(microseconds: 500)
        slow.delayWrites(microseconds: 500)
        return try await run(request, on: slow, chunkSize: 4 * 1024, pauseWhen: { event in
            if case .progress(let progress) = event { return progress.copiedBytes > 32 * 1024 }
            return false
        })
    }

    /// A fresh offload as `TransferSession.start()` builds it from a reviewed
    /// preflight (`AppModel.startDraftOffloads`). Keep the
    /// `requireNewOutputRoots` expression identical to TransferSession.swift.
    private static func freshRequest(for preflight: TransferPreflight, spool: URL) -> TransferRequest {
        let resumeManifest: TransferManifest? = nil
        let retryManifest: TransferManifest? = nil
        let duplicateManifests: [String: TransferManifest] = [:]
        return TransferRequest(
            sourceRoot: preflight.source,
            destinations: preflight.requestDestinations,
            algorithm: .xxh3,
            verificationProfile: .standard,
            sourceFingerprint: preflight.sourceFingerprint,
            spoolDirectory: spool,
            allowSameVolume: true, // fixtures share the temp volume
            requireNewOutputRoots: resumeManifest == nil && retryManifest == nil && duplicateManifests.isEmpty,
            resumeManifest: resumeManifest,
            retryManifest: retryManifest,
            includedRelativePaths: preflight.includedRelativePaths,
            duplicateManifests: duplicateManifests
        )
    }

    /// The parent manifest exactly as `AppModel.retryFailures` loads it:
    /// `TransferSession.manifestURL`, the first manifest location.
    private static func parentManifest(of parent: TransferReport) throws -> TransferManifest {
        let location = try #require(parent.manifestLocations.first)
        let url = location.appendingPathComponent(ManifestWriter.manifestFileName(shortID: parent.shortID))
        return try ManifestWriter.decode(Data(contentsOf: url))
    }

    /// What `AppModel.retryFailures` gives the repair session for `output`,
    /// and the request `TransferSession.start()` then builds from it: the
    /// parent's failed paths at that one destination, the parent manifest's
    /// fingerprint (or the session's when the manifest has none), and no
    /// fresh-folder rule. `carrying` replaces the fingerprint, standing in
    /// for a request that was not built by `retryFailures`.
    private static func repairRequest(
        parent: TransferReport,
        manifest: TransferManifest,
        sessionFingerprint: String?,
        base: URL,
        output: URL,
        spool: URL,
        carrying fingerprintOverride: String? = nil
    ) -> TransferRequest {
        let paths = Set(parent.items.compactMap { item -> String? in
            if case .failed = item.outcomes[output] { return item.item.relativePath }
            return nil
        })
        let resumeManifest: TransferManifest? = nil
        let retryManifest: TransferManifest? = manifest
        let duplicateManifests: [String: TransferManifest] = [:]
        return TransferRequest(
            sourceRoot: parent.sourceRoot,
            destinations: [TransferDestination(baseRoot: base, outputRoot: output)],
            algorithm: parent.algorithm,
            verificationProfile: parent.verificationProfile,
            taskID: parent.taskID,
            sourceFingerprint: fingerprintOverride ?? manifest.sourceFingerprint ?? sessionFingerprint,
            spoolDirectory: spool,
            allowSameVolume: true, // the parent's acknowledgement; fixtures share the temp volume
            requireNewOutputRoots: resumeManifest == nil && retryManifest == nil && duplicateManifests.isEmpty,
            resumeManifest: resumeManifest,
            retryManifest: retryManifest,
            includedRelativePaths: paths,
            duplicateManifests: duplicateManifests
        )
    }

    /// What `AppModel.resume` gives the session that resumes `paused`, and
    /// the request `TransferSession.start()` then builds from it: the paused
    /// attempt's own destination and task, its manifest's fingerprint (or the
    /// session's when the manifest has none), and no fresh-folder rule.
    /// `scope` is the file scope: `nil` (the whole source) as
    /// `AppModel.resume` builds it here, or the paused attempt's own reviewed
    /// files as a scope-preserving resume builds it.
    private static func resumeRequest(
        paused: TransferReport,
        manifest: TransferManifest,
        sessionFingerprint: String?,
        base: URL,
        output: URL,
        spool: URL,
        scope: Set<String>?
    ) -> TransferRequest {
        let resumeManifest: TransferManifest? = manifest
        let retryManifest: TransferManifest? = nil
        let duplicateManifests: [String: TransferManifest] = [:]
        return TransferRequest(
            sourceRoot: paused.sourceRoot,
            destinations: [TransferDestination(baseRoot: base, outputRoot: output)],
            algorithm: paused.algorithm,
            verificationProfile: paused.verificationProfile,
            taskID: paused.taskID,
            sourceFingerprint: manifest.sourceFingerprint ?? sessionFingerprint,
            spoolDirectory: spool,
            allowSameVolume: true, // the paused attempt's acknowledgement; fixtures share the temp volume
            requireNewOutputRoots: resumeManifest == nil && retryManifest == nil && duplicateManifests.isEmpty,
            resumeManifest: resumeManifest,
            retryManifest: retryManifest,
            includedRelativePaths: scope,
            duplicateManifests: duplicateManifests
        )
    }

    private struct FailedParent {
        let source: URL
        let base: URL
        let output: URL
        let preflight: TransferPreflight
        let report: TransferReport
        let manifest: TransferManifest
    }

    /// A reviewed offload, started like the app starts it, whose copies of
    /// `corrupted` (by default `corruptedPath` alone) fail verification while
    /// every other file verifies: Repair is then offered for exactly those
    /// pairs.
    private static func failedParent(
        _ fixtures: FixtureBuilder,
        selection: Set<String>? = nil,
        corrupting corrupted: Set<String> = [corruptedPath]
    ) async throws -> FailedParent {
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let base = try fixtures.makeDestination(named: "RAID")
        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [base], folderName: folderName,
            algorithm: .xxh3, layout: .newFolder, includedRelativePaths: selection)
        try #require(preflight.canStart, "\(preflight.blockingIssues)")
        let output = try #require(preflight.destinations.first?.output)

        let faulty = FailpointFileSystem(base: RealFileSystem())
        for path in corrupted {
            faulty.corruptFirstByteOnWrite(pathSuffix: "\(folderName)/\(path)")
        }
        let report = try await run(
            freshRequest(for: preflight, spool: fixtures.root.appendingPathComponent("parent-spool")),
            on: faulty)
        try #require(report.status == .failed, "issues: \(report.issues)")
        try #require(corrupted.isSubset(of: Set(report.items.map(\.item.relativePath))))
        for item in report.items {
            let outcome = item.outcomes[output]
            guard corrupted.contains(item.item.relativePath) else {
                try #require(outcome == .verified, "\(item.item.relativePath)")
                continue
            }
            var failedVerification = false
            if case .failed(.checksumMismatch)? = outcome { failedVerification = true }
            try #require(failedVerification, "\(item.item.relativePath): \(String(describing: outcome))")
        }
        return FailedParent(
            source: source, base: base, output: output, preflight: preflight,
            report: report, manifest: try parentManifest(of: report))
    }

    private static func repair(_ parent: FailedParent, _ fixtures: FixtureBuilder) async throws -> TransferReport {
        try await run(repairRequest(
            parent: parent.report,
            manifest: parent.manifest,
            sessionFingerprint: parent.preflight.sourceFingerprint,
            base: parent.base,
            output: parent.output,
            spool: fixtures.root.appendingPathComponent("repair-spool")))
    }

    private static func manifestNames(in output: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix("doppelganger-manifest-") })
    }

    // MARK: - The app's partial repair

    /// The finding: every partial repair the app started was vetoed with
    /// "The source plan changed after review", because the parent's
    /// whole-plan fingerprint was compared with the repaired subset.
    @Test func aPartialRepairStartedLikeTheAppVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let parent = try await Self.failedParent(fixtures)
        try #require(parent.manifest.sourceFingerprint == parent.preflight.sourceFingerprint)

        let repaired = try await Self.repair(parent, fixtures)

        #expect(repaired.status == .verified, "issues: \(repaired.issues)")
        #expect(repaired.items.map(\.item.relativePath) == [Self.corruptedPath])
        #expect(repaired.outcome(Self.corruptedPath, at: parent.output) == .verified)
        #expect(
            try fixtures.bytes(at: parent.output.appendingPathComponent(Self.corruptedPath))
                == fixtures.bytes(at: parent.source.appendingPathComponent(Self.corruptedPath))
        )
        #expect(!repaired.issues.contains { $0.contains("source plan changed") })
        // The repair records the plan identity it was checked against.
        #expect(repaired.sourceFingerprint == parent.preflight.sourceFingerprint)
    }

    /// A parent that copied only an operator's selection: its fingerprint
    /// covers the selection, so the repair is checked against the selection,
    /// never against the whole card.
    @Test func aSelectionOnlyParentsPartialRepairVerifies() async throws {
        let fixtures = try FixtureBuilder()
        let selection: Set<String> = [Self.corruptedPath, "DCIM/100MEDIA/b.bin"]
        let parent = try await Self.failedParent(fixtures, selection: selection)
        try #require(parent.preflight.includedRelativePaths == selection)
        try #require(Set(parent.manifest.items.map(\.relativePath)) == selection)

        let repaired = try await Self.repair(parent, fixtures)

        #expect(repaired.status == .verified, "issues: \(repaired.issues)")
        #expect(repaired.items.map(\.item.relativePath) == [Self.corruptedPath])
        #expect(
            try fixtures.bytes(at: parent.output.appendingPathComponent(Self.corruptedPath))
                == fixtures.bytes(at: parent.source.appendingPathComponent(Self.corruptedPath))
        )
        #expect(!FileManager.default.fileExists(
            atPath: parent.output.appendingPathComponent("MISC/c.txt").path))
    }

    // MARK: - The gate still holds

    enum SourceChange: String, CaseIterable, Sendable {
        /// Same bytes, a new modification time.
        case retouched
        /// Different bytes and size.
        case rewritten
        /// Gone from the card.
        case removed
    }

    /// A file of the parent's plan that the repair does not address changes
    /// after the parent ran. Only the fingerprint can see it (the repair's
    /// own scope still matches the parent's records), and it must veto the
    /// repair before anything at the destination is touched.
    @Test(arguments: SourceChange.allCases)
    func aSourceThatChangedSinceTheParentIsStillVetoed(_ change: SourceChange) async throws {
        let fixtures = try FixtureBuilder()
        let parent = try await Self.failedParent(fixtures)
        let target = parent.output.appendingPathComponent(Self.corruptedPath)
        let failedBytes = try fixtures.bytes(at: target)
        let manifestsBefore = try Self.manifestNames(in: parent.output)

        let other = parent.source.appendingPathComponent("DCIM/100MEDIA/b.bin")
        switch change {
        case .retouched:
            let modified = try #require(
                try FileManager.default.attributesOfItem(atPath: other.path)[.modificationDate] as? Date)
            try FileManager.default.setAttributes(
                [.modificationDate: modified.addingTimeInterval(-3_600)], ofItemAtPath: other.path)
        case .rewritten:
            try Data(FixtureBuilder.FileSpec("DCIM/100MEDIA/b.bin", size: 150_001, seed: 99).bytes)
                .write(to: other)
        case .removed:
            try FileManager.default.removeItem(at: other)
        }

        let repaired = try await Self.repair(parent, fixtures)

        #expect(repaired.status == .failed)
        #expect(repaired.issues.contains("The source plan changed after review; run preflight again."),
                "issues: \(repaired.issues)")
        #expect(repaired.verifiedCount == 0)
        #expect(try fixtures.bytes(at: target) == failedBytes, "the parent's failed copy was touched")
        #expect(!FileManager.default.fileExists(
            atPath: parent.output.appendingPathComponent(".doppelganger-failed").path))
        #expect(try Self.manifestNames(in: parent.output) == manifestsBefore)
    }

    enum ManifestDefect: String, CaseIterable, Sendable {
        /// Names no files, so it describes no plan.
        case noItems
        /// Records a different plan identity than the one the retry carries.
        case otherPlanIdentity
    }

    /// Fail closed: a retry whose parent manifest cannot vouch for the
    /// fingerprint it carries never reaches the destination.
    @Test(arguments: ManifestDefect.allCases)
    func aParentManifestThatCannotVouchForThePlanVetoesTheRepair(_ defect: ManifestDefect) async throws {
        let fixtures = try FixtureBuilder()
        let parent = try await Self.failedParent(fixtures)
        let target = parent.output.appendingPathComponent(Self.corruptedPath)
        let failedBytes = try fixtures.bytes(at: target)
        let manifestsBefore = try Self.manifestNames(in: parent.output)

        var manifest = parent.manifest
        var reviewedFingerprint: String?
        switch defect {
        case .noItems:
            manifest.items = []
        case .otherPlanIdentity:
            manifest.sourceFingerprint = String(repeating: "0", count: 16)
            // The request still carries the reviewed fingerprint, which
            // the manifest no longer records.
            reviewedFingerprint = parent.preflight.sourceFingerprint
        }

        let repaired = try await Self.run(Self.repairRequest(
            parent: parent.report, manifest: manifest,
            sessionFingerprint: parent.preflight.sourceFingerprint,
            base: parent.base, output: parent.output,
            spool: fixtures.root.appendingPathComponent("repair-spool"),
            carrying: reviewedFingerprint))

        #expect(repaired.status == .failed)
        #expect(repaired.issues.contains { $0.hasPrefix("The failed attempt's manifest does not describe") },
                "issues: \(repaired.issues)")
        #expect(try fixtures.bytes(at: target) == failedBytes, "the parent's failed copy was touched")
        #expect(!FileManager.default.fileExists(
            atPath: parent.output.appendingPathComponent(".doppelganger-failed").path))
        #expect(try Self.manifestNames(in: parent.output) == manifestsBefore)
    }

    // MARK: - Unchanged for everything else

    /// Control: an operator's selection is still checked against exactly the
    /// selected items. The whole card's fingerprint does not describe it.
    @Test func aSelectionOnlyOffloadIsStillCheckedAgainstExactlyItsSelection() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let base = try fixtures.makeDestination(named: "RAID")
        let selection: Set<String> = [Self.corruptedPath]
        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [base], folderName: Self.folderName,
            algorithm: .xxh3, layout: .newFolder, includedRelativePaths: selection)
        try #require(preflight.canStart, "\(preflight.blockingIssues)")
        let wholeCard = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        try #require(wholeCard != preflight.sourceFingerprint)
        let reviewed = Self.freshRequest(for: preflight, spool: fixtures.root.appendingPathComponent("spool"))
        let mislabelled = TransferRequest(
            sourceRoot: reviewed.sourceRoot, destinations: reviewed.destinations,
            algorithm: reviewed.algorithm, verificationProfile: reviewed.verificationProfile,
            sourceFingerprint: wholeCard,
            spoolDirectory: fixtures.root.appendingPathComponent("spool-whole"),
            allowSameVolume: true, requireNewOutputRoots: true,
            includedRelativePaths: reviewed.includedRelativePaths)

        let refused = try await Self.run(mislabelled)
        #expect(refused.status == .failed)
        #expect(refused.issues.contains("The source plan changed after review; run preflight again."))

        let copied = try await Self.run(reviewed)
        #expect(copied.status == .verified, "issues: \(copied.issues)")
        #expect(copied.items.map(\.item.relativePath) == [Self.corruptedPath])
    }

    // MARK: - Continuing a partial repair

    enum RepairContinuation: String, CaseIterable, Sendable {
        /// Retry Failures on a partial repair that failed again.
        case repairOfTheRepair
        /// Resume of a paused partial repair over the whole source, as
        /// `AppModel.resume` builds it.
        case resumeOfTheWholeSource
        /// Resume of a paused partial repair over exactly the files it
        /// planned, as a scope-preserving resume builds it.
        case resumeOfTheRepairedFiles
    }

    private struct StoppedRepair {
        let parent: FailedParent
        let report: TransferReport
        let manifest: TransferManifest
    }

    /// A partial repair of a parent whose `corruptedPath` and
    /// `secondCorruptedPath` copies failed, stopped where `continuation`
    /// picks it up: failed again (its own copy of `corruptedPath` is corrupted
    /// on write too) or paused after its first file.
    private static func stoppedRepair(
        for continuation: RepairContinuation,
        _ fixtures: FixtureBuilder
    ) async throws -> StoppedRepair {
        let repaired: Set<String> = [corruptedPath, secondCorruptedPath]
        let parent = try await failedParent(fixtures, corrupting: repaired)
        let request = repairRequest(
            parent: parent.report,
            manifest: parent.manifest,
            sessionFingerprint: parent.preflight.sourceFingerprint,
            base: parent.base,
            output: parent.output,
            spool: fixtures.root.appendingPathComponent("repair-spool"))
        let report: TransferReport
        switch continuation {
        case .repairOfTheRepair:
            let faulty = FailpointFileSystem(base: RealFileSystem())
            faulty.corruptFirstByteOnWrite(pathSuffix: "\(folderName)/\(corruptedPath)")
            report = try await run(request, on: faulty)
            try #require(report.status == .failed, "issues: \(report.issues)")
            let outcome = report.outcome(corruptedPath, at: parent.output)
            var failedVerification = false
            if case .failed(.checksumMismatch)? = outcome { failedVerification = true }
            try #require(failedVerification, "\(corruptedPath): \(String(describing: outcome))")
            try #require(report.outcome(secondCorruptedPath, at: parent.output) == .verified)
        case .resumeOfTheWholeSource, .resumeOfTheRepairedFiles:
            report = try await runPausingAfterTheFirstFile(request)
            try #require(report.status == .paused, "issues: \(report.issues)")
            try #require(report.outcome(corruptedPath, at: parent.output) == .verified)
            // Not reached: the parent's failed copy is still at the target.
            try #require(report.outcome(secondCorruptedPath, at: parent.output) == .skipped(.paused))
        }
        // The premise: the repair's record carries its parent's whole-plan
        // identity over only the files it repaired.
        let manifest = try parentManifest(of: report)
        try #require(manifest.sourceFingerprint == parent.preflight.sourceFingerprint)
        try #require(Set(manifest.items.map(\.relativePath)) == repaired)
        return StoppedRepair(parent: parent, report: report, manifest: manifest)
    }

    /// The request the app builds to continue `repair` as `continuation`.
    private static func continuationRequest(
        _ continuation: RepairContinuation,
        of repair: StoppedRepair,
        spool: URL
    ) -> TransferRequest {
        // The repair session's own fingerprint is the one it was handed.
        let sessionFingerprint = repair.parent.manifest.sourceFingerprint ?? repair.parent.preflight.sourceFingerprint
        switch continuation {
        case .repairOfTheRepair:
            return repairRequest(
                parent: repair.report, manifest: repair.manifest,
                sessionFingerprint: sessionFingerprint,
                base: repair.parent.base, output: repair.parent.output, spool: spool)
        case .resumeOfTheWholeSource, .resumeOfTheRepairedFiles:
            return resumeRequest(
                paused: repair.report, manifest: repair.manifest,
                sessionFingerprint: sessionFingerprint,
                base: repair.parent.base, output: repair.parent.output, spool: spool,
                scope: continuation == .resumeOfTheWholeSource
                    ? nil : Set(repair.manifest.items.map(\.relativePath)))
        }
    }

    /// The findings: a resume of a paused partial repair either ran as a
    /// whole-source offload into the parent's folder (every file the parent
    /// verified, and every failed copy the repair had not reached, recorded
    /// as a digest-less name collision) or was refused as a changed source;
    /// a repair of a failed partial repair was refused as a changed source.
    /// Nothing on the source changed. Each is refused without touching the
    /// destination, naming the record it cannot continue.
    @Test(arguments: RepairContinuation.allCases)
    func aContinuedPartialRepairIsRefusedUntouchedForItsRecord(_ continuation: RepairContinuation) async throws {
        let fixtures = try FixtureBuilder()
        let repair = try await Self.stoppedRepair(for: continuation, fixtures)
        let destinationBefore = try fixtures.digestSnapshot(of: repair.parent.output)

        let refused = try await Self.run(Self.continuationRequest(
            continuation, of: repair, spool: fixtures.root.appendingPathComponent("continuation-spool")))

        #expect(refused.status == .failed)
        let expected = continuation == .repairOfTheRepair ? Self.retryRecordRefused : Self.resumeRecordRefused
        #expect(refused.issues.contains(expected), "issues: \(refused.issues)")
        #expect(!refused.issues.contains(Self.sourceChanged))
        #expect(refused.verifiedCount == 0)
        #expect(refused.failedCount == 0, "no pair may be recorded as a collision")
        #expect(try fixtures.digestSnapshot(of: repair.parent.output) == destinationBefore)
    }

    /// The refusal above must not hide a real change: a file the repair's
    /// record lists, retouched since, still reads as a changed source.
    @Test(arguments: RepairContinuation.allCases)
    func aSourceChangedUnderAContinuedRepairStillReadsAsChanged(_ continuation: RepairContinuation) async throws {
        let fixtures = try FixtureBuilder()
        let repair = try await Self.stoppedRepair(for: continuation, fixtures)
        let retouched = repair.parent.source.appendingPathComponent(Self.secondCorruptedPath)
        let modified = try #require(
            try FileManager.default.attributesOfItem(atPath: retouched.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes(
            [.modificationDate: modified.addingTimeInterval(-3_600)], ofItemAtPath: retouched.path)
        let destinationBefore = try fixtures.digestSnapshot(of: repair.parent.output)

        let refused = try await Self.run(Self.continuationRequest(
            continuation, of: repair, spool: fixtures.root.appendingPathComponent("continuation-spool")))

        #expect(refused.status == .failed)
        #expect(refused.issues.contains(Self.sourceChanged), "issues: \(refused.issues)")
        #expect(try fixtures.digestSnapshot(of: repair.parent.output) == destinationBefore)
    }

    // MARK: - A paused record must list the plan it resumes

    enum PausedRecordDefect: String, CaseIterable, Sendable {
        /// One planned file is missing from the record.
        case omitsAPlannedFile
        /// One file is listed twice.
        case listsAFileTwice
    }

    /// A resume continues exactly the plan its paused record lists. A record
    /// that lists any other set of files is refused before any destination is
    /// touched, even when the source still matches the fingerprint it
    /// carries; the paused attempt's own record still resumes to Verified.
    @Test(arguments: PausedRecordDefect.allCases)
    func aPausedRecordThatDoesNotListThePlanIsRefusedUntouched(_ defect: PausedRecordDefect) async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let base = try fixtures.makeDestination(named: "RAID")
        let preflight = await TransferPreflight.inspect(
            source: source, destinationBases: [base], folderName: Self.folderName,
            algorithm: .xxh3, layout: .newFolder)
        try #require(preflight.canStart, "\(preflight.blockingIssues)")
        let output = try #require(preflight.destinations.first?.output)
        let paused = try await Self.runPausingAfterTheFirstFile(
            Self.freshRequest(for: preflight, spool: fixtures.root.appendingPathComponent("pause-spool")))
        try #require(paused.status == .paused, "issues: \(paused.issues)")
        try #require(paused.verifiedCount > 0)
        try #require(paused.verifiedCount < EngineHarness.standardFiles.count)
        let manifest = try Self.parentManifest(of: paused)
        try #require(manifest.sourceFingerprint == preflight.sourceFingerprint)

        var record = manifest
        switch defect {
        case .omitsAPlannedFile:
            record.items.removeAll { $0.relativePath == "MISC/c.txt" }
        case .listsAFileTwice:
            record.items.append(record.items[0])
        }
        let destinationBefore = try fixtures.digestSnapshot(of: output)

        let refused = try await Self.run(Self.resumeRequest(
            paused: paused, manifest: record, sessionFingerprint: preflight.sourceFingerprint,
            base: base, output: output,
            spool: fixtures.root.appendingPathComponent("refused-spool"), scope: nil))

        #expect(refused.status == .failed)
        #expect(refused.issues.contains(Self.resumeRecordRefused), "issues: \(refused.issues)")
        #expect(try fixtures.digestSnapshot(of: output) == destinationBefore)

        // Control: the paused attempt's own record resumes it.
        let resumed = try await Self.run(Self.resumeRequest(
            paused: paused, manifest: manifest, sessionFingerprint: preflight.sourceFingerprint,
            base: base, output: output,
            spool: fixtures.root.appendingPathComponent("resume-spool"), scope: nil))
        #expect(resumed.status == .verified, "issues: \(resumed.issues)")
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: output.appendingPathComponent(spec.path)) == spec.bytes, "\(spec.path)")
        }
    }
}
