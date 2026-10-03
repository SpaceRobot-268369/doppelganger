import Foundation
import Testing
@testable import Doppelganger

/// engine-3 / G07: a paused Fast attempt resumes without failing (or
/// rewriting) the files it had already transferred, and never vouches for
/// them beyond what Fast proves (size and modification time, no read-back).
/// Synthetic fixtures in a scratch directory only.
struct FastPauseResumeTests {
    /// Enough to show a resume left a copy exactly where and as it was.
    private struct FileIdentity: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            inode = try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
            size = try #require((attributes[.size] as? NSNumber)?.uint64Value)
            modified = try #require(attributes[.modificationDate] as? Date)
        }
    }

    private static func identities(_ paths: [String], at destination: URL) throws -> [String: FileIdentity] {
        var result: [String: FileIdentity] = [:]
        for path in paths { result[path] = try FileIdentity(destination.appendingPathComponent(path)) }
        return result
    }

    private static var allPaths: [String] { EngineHarness.standardFiles.map(\.path) }

    /// Source bytes this run copied (the hub counts each chunk once); 0 means
    /// nothing was read from the source for copying and nothing was written.
    private static func copiedBytes(_ run: EngineHarness.Run) -> Int64 {
        run.events.reduce(Int64(0)) { latest, event in
            if case .progress(let progress) = event { return max(latest, progress.copiedBytes) }
            return latest
        }
    }

    /// Hidden engine names (staging files, the quarantine tree) anywhere under
    /// the destination. A clean resume leaves none.
    private static func engineLeftovers(in destination: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)
        else { return ["<unreadable destination>"] }
        return walker.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasPrefix(".doppelganger-") }
    }

    /// A genuine Fast pause, timed exactly like PauseResumeTests: the request
    /// lands while the first file is mid-copy, so the pass stops after it.
    private static func pausedFastRun(
        _ fixtures: FixtureBuilder,
        source: URL,
        destination: URL,
        spool: String,
        resumeManifest: TransferManifest? = nil
    ) async throws -> EngineHarness.Run {
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        fileSystem.delayWrites(microseconds: 500)
        return try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent(spool),
            verificationProfile: .fast,
            resumeManifest: resumeManifest,
            chunkSize: 4 * 1024,
            pauseWhen: { event in
                if case .progress(let progress) = event { return progress.copiedBytes > 32 * 1024 }
                return false
            }
        )
    }

    /// A Fast parent whose copy pass reached every file, recorded as the
    /// paused attempt the card would resume (Pause pressed during the last
    /// file). The restore keys on per-pair records, not on the parent's
    /// terminal status, so this is a deterministic stand-in for a real pause.
    private static func fullyTransferredFastParent(
        _ fixtures: FixtureBuilder,
        source: URL,
        destination: URL
    ) async throws -> TransferManifest {
        let parent = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("parent-spool"),
            verificationProfile: .fast
        )
        try #require(parent.report.status == .transferredPendingVerification)
        var manifest = try EngineHarness.decodeManifest(at: destination, shortID: parent.report.shortID)
        manifest.status = TransferStatus.paused.rawValue
        return manifest
    }

    private static func resume(
        _ fixtures: FixtureBuilder,
        source: URL,
        destination: URL,
        from parent: TransferManifest,
        profile: VerificationProfile = .fast
    ) async throws -> EngineHarness.Run {
        try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("resume-spool-\(UUID().uuidString.prefix(8))"),
            verificationProfile: profile,
            resumeManifest: parent
        )
    }

    private static func standaloneVerify(
        _ fixtures: FixtureBuilder,
        destination: URL,
        shortID: String
    ) async throws -> TransferReport {
        try await StandaloneVerificationService.verify(
            id: UUID(),
            referenceURL: destination.appendingPathComponent(ManifestWriter.manifestFileName(shortID: shortID)),
            mediaRoot: destination,
            operatorProfile: OperatorProfile(displayName: "Test Operator"),
            projectID: nil,
            spoolDirectory: fixtures.root.appendingPathComponent("verify-spool-\(shortID)")
        )
    }

    private static func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Port of Repro_G07.repro_fastResumeKeepsPrePauseTransfersPending, tightened.
    @Test func fastResumeKeepsPrePauseTransfersPendingWithoutRewritingThem() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "fast-resume-destination")

        let paused = try await Self.pausedFastRun(
            fixtures, source: source, destination: destination, spool: "fast-pause-spool")

        // A genuine partial Fast pause, as the card would show
        // "Paused safely · Resume available".
        try #require(paused.report.status == .paused)
        try #require(paused.report.failedCount == 0)
        try #require(paused.report.pendingVerificationCount > 0)
        try #require(paused.report.pendingVerificationCount < EngineHarness.standardFiles.count)
        let prePausePaths = paused.report.items
            .filter { $0.outcomes[destination]?.isTransferredPendingVerification == true }
            .map(\.item.relativePath)
        let before = try Self.identities(prePausePaths, at: destination)
        let pausedManifestURL = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: paused.report.shortID))
        let pausedManifestBytes = try Data(contentsOf: pausedManifestURL)
        let pausedManifest = try ManifestWriter.decode(pausedManifestBytes)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: pausedManifest)

        for spec in EngineHarness.standardFiles {
            #expect(resumed.report.outcome(spec.path, at: destination) == .transferredPendingVerification,
                    "\(spec.path) must be transferred, pending verification — never a name collision")
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(resumed.report.status == .transferredPendingVerification)
        #expect(resumed.report.failedCount == 0)
        #expect(resumed.report.verifiedCount == 0)
        #expect(resumed.report.pendingVerificationCount == EngineHarness.standardFiles.count)
        // Not rewritten, not re-read: only the files the pause left behind
        // were copied by the resume.
        #expect(try Self.identities(prePausePaths, at: destination) == before)
        let remainingBytes = EngineHarness.standardFiles
            .filter { !prePausePaths.contains($0.path) }
            .reduce(Int64(0)) { $0 + Int64($1.size) }
        #expect(Self.copiedBytes(resumed) == remainingBytes)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
        // Attempts are immutable.
        #expect(try Data(contentsOf: pausedManifestURL) == pausedManifestBytes)

        let resumedManifest = try EngineHarness.decodeManifest(at: destination, shortID: resumed.report.shortID)
        #expect(resumedManifest.status == TransferStatus.transferredPendingVerification.rawValue)
        for record in resumedManifest.items {
            #expect(record.digest != nil, "\(record.relativePath) needs a digest for a later read-back")
            #expect(record.results.map(\.status) == ["transferred-pending-verification"])
        }
        for path in prePausePaths {
            let carried = resumedManifest.items.first { $0.relativePath == path }?.digest
            let original = pausedManifest.items.first { $0.relativePath == path }?.digest
            #expect(carried != nil && carried == original)
        }
        #expect(resumed.logMessages.contains { $0.hasPrefix("Resume: kept \(prePausePaths.count) ") })

        // The promised independent read-back works on the resumed manifest.
        let verification = try await Self.standaloneVerify(
            fixtures, destination: destination, shortID: resumed.report.shortID)
        #expect(verification.status == .verified, "issues: \(verification.issues)")
        #expect(verification.verifiedCount == EngineHarness.standardFiles.count)
    }

    @Test func fastPauseResumePauseResumeCarriesPendingPairsForward() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")

        let first = try await Self.pausedFastRun(
            fixtures, source: source, destination: destination, spool: "first")
        try #require(first.report.status == .paused)
        try #require(first.report.pendingVerificationCount > 0)
        try #require(first.report.pendingVerificationCount < EngineHarness.standardFiles.count)
        let firstManifest = try EngineHarness.decodeManifest(at: destination, shortID: first.report.shortID)

        // The pause threshold counts only newly copied bytes, so the second
        // attempt stops after the next large file.
        let second = try await Self.pausedFastRun(
            fixtures, source: source, destination: destination, spool: "second",
            resumeManifest: firstManifest)
        try #require(second.report.status == .paused)
        try #require(second.report.failedCount == 0)
        try #require(second.report.pendingVerificationCount > first.report.pendingVerificationCount)
        try #require(second.report.pendingVerificationCount < EngineHarness.standardFiles.count)
        let secondManifest = try EngineHarness.decodeManifest(at: destination, shortID: second.report.shortID)

        let third = try await Self.resume(fixtures, source: source, destination: destination, from: secondManifest)

        #expect(third.report.status == .transferredPendingVerification)
        #expect(third.report.failedCount == 0)
        #expect(third.report.pendingVerificationCount == EngineHarness.standardFiles.count)
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
        let thirdManifest = try EngineHarness.decodeManifest(at: destination, shortID: third.report.shortID)
        for record in firstManifest.items {
            guard let original = record.digest else { continue }
            #expect(thirdManifest.items.first { $0.relativePath == record.relativePath }?.digest == original)
        }
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    /// The pause landed during the last file: the resume has nothing to copy.
    @Test func fastResumeOfFullyTransferredParentWritesNothing() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        let before = try Self.identities(Self.allPaths, at: destination)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        for path in Self.allPaths {
            #expect(resumed.report.outcome(path, at: destination) == .transferredPendingVerification)
        }
        #expect(resumed.report.status == .transferredPendingVerification)
        #expect(Self.copiedBytes(resumed) == 0)
        #expect(try Self.identities(Self.allPaths, at: destination) == before)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    enum PrePauseTamper: String, CaseIterable, Sendable {
        /// One byte appended: the size no longer matches.
        case grew
        /// Same bytes, timestamp an hour later: not the copy this task published.
        case retimed
    }

    /// A copy whose metadata changed since the pause is not reused. It fails
    /// as a name collision and is left exactly as found, never overwritten.
    @Test(arguments: PrePauseTamper.allCases)
    func fastResumeRefusesAPrePauseCopyWhoseMetadataChanged(_ tamper: PrePauseTamper) async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        let tampered = Self.allPaths[0]
        let tamperedURL = destination.appendingPathComponent(tampered)
        switch tamper {
        case .grew:
            let handle = try FileHandle(forWritingTo: tamperedURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: [0])
            try handle.close()
        case .retimed:
            let modified = try #require(
                try FileManager.default.attributesOfItem(atPath: tamperedURL.path)[.modificationDate] as? Date)
            try Self.setModificationDate(modified.addingTimeInterval(3600), at: tamperedURL)
        }
        let tamperedBytes = try fixtures.bytes(at: tamperedURL)
        let before = try Self.identities(Self.allPaths, at: destination)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        #expect(resumed.report.outcome(tampered, at: destination) == .failed(.nameCollision))
        #expect(try fixtures.bytes(at: tamperedURL) == tamperedBytes)
        for path in Self.allPaths.dropFirst() {
            #expect(resumed.report.outcome(path, at: destination) == .transferredPendingVerification)
        }
        #expect(try Self.identities(Self.allPaths, at: destination) == before)
        #expect(resumed.report.status == .failed)
        #expect(resumed.report.verifiedCount == 0)
        #expect(Self.copiedBytes(resumed) == 0)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    /// HFS+ stores timestamps to the second and FAT to two seconds; a copy
    /// published on such a destination still reads as this task's copy.
    @Test func fastResumeToleratesCoarseDestinationTimestamps() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        let coarse = destination.appendingPathComponent(Self.allPaths[0])
        let modified = try #require(
            try FileManager.default.attributesOfItem(atPath: coarse.path)[.modificationDate] as? Date)
        try Self.setModificationDate(modified.addingTimeInterval(-1.5), at: coarse)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        #expect(resumed.report.outcome(Self.allPaths[0], at: destination) == .transferredPendingVerification)
        #expect(resumed.report.status == .transferredPendingVerification)
        #expect(Self.copiedBytes(resumed) == 0)
    }

    enum PublishTime: String, CaseIterable, Sendable {
        /// Inside the paused attempt's run: a destination that does not keep
        /// timestamps left the copy with the time it was published.
        case duringThePausedRun
        /// After the paused run and far from the source's time.
        case afterThePausedRun
    }

    /// Some exFAT and SMB destinations do not keep the source's timestamp, so
    /// a copy keeps the time it was published. That time falls inside the
    /// paused attempt's own run and still marks the copy as this task's; any
    /// other time does not. The source clips are dated well before the run so
    /// the two clocks cannot be confused.
    @Test(arguments: PublishTime.allCases)
    func fastResumeAcceptsAPublishTimeOnlyFromThePausedRun(_ publishTime: PublishTime) async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let recorded = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01, in camera
        for path in Self.allPaths {
            try Self.setModificationDate(recorded, at: source.appendingPathComponent(path))
        }
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let started = try Date(parent.startedAt, strategy: iso)
        let finished = try Date(parent.finishedAt, strategy: iso)
        let stamped = destination.appendingPathComponent(Self.allPaths[0])
        try Self.setModificationDate(
            publishTime == .duringThePausedRun
                ? started.addingTimeInterval(finished.timeIntervalSince(started) / 2)
                : finished.addingTimeInterval(60),
            at: stamped
        )
        let stampedBytes = try fixtures.bytes(at: stamped)
        let before = try Self.identities(Self.allPaths, at: destination)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        switch publishTime {
        case .duringThePausedRun:
            #expect(resumed.report.outcome(Self.allPaths[0], at: destination) == .transferredPendingVerification)
            #expect(resumed.report.status == .transferredPendingVerification)
        case .afterThePausedRun:
            #expect(resumed.report.outcome(Self.allPaths[0], at: destination) == .failed(.nameCollision))
            #expect(resumed.report.status == .failed)
        }
        for path in Self.allPaths.dropFirst() {
            #expect(resumed.report.outcome(path, at: destination) == .transferredPendingVerification)
        }
        #expect(resumed.report.verifiedCount == 0)
        #expect(try fixtures.bytes(at: stamped) == stampedBytes)
        #expect(try Self.identities(Self.allPaths, at: destination) == before)
        #expect(Self.copiedBytes(resumed) == 0)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    /// Size and timestamp are identity, not proof: a same-size corrupt copy
    /// is carried as pending, never verified, and the read-back catches it.
    @Test func fastResumeNeverVouchesForBytesItDidNotReadBack() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        let corrupted = Self.allPaths[1]
        let corruptedURL = destination.appendingPathComponent(corrupted)
        let modified = try #require(
            try FileManager.default.attributesOfItem(atPath: corruptedURL.path)[.modificationDate] as? Date)
        var bytes = try fixtures.bytes(at: corruptedURL)
        bytes[0] ^= 0xFF
        let handle = try FileHandle(forUpdating: corruptedURL)
        try handle.write(contentsOf: bytes)
        try handle.close()
        try Self.setModificationDate(modified, at: corruptedURL)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        #expect(resumed.report.outcome(corrupted, at: destination) == .transferredPendingVerification)
        #expect(resumed.report.status == .transferredPendingVerification)
        #expect(resumed.report.verifiedCount == 0)
        #expect(Self.copiedBytes(resumed) == 0)

        let verification = try await Self.standaloneVerify(
            fixtures, destination: destination, shortID: resumed.report.shortID)
        #expect(verification.status == .failed)
        let parentDigest = parent.items.first { $0.relativePath == corrupted }?.digest
        guard case .failed(.checksumMismatch(let expected, _))? = verification.outcome(corrupted, at: destination) else {
            let got = String(describing: verification.outcome(corrupted, at: destination))
            Issue.record("expected a checksum mismatch for \(corrupted), got \(got)")
            return
        }
        #expect(expected == parentDigest)
        for path in Self.allPaths where path != corrupted {
            #expect(verification.outcome(path, at: destination) == .verified)
        }
    }

    @Test func fastResumeCopiesAMissingPrePauseFileAgain() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        try FileManager.default.removeItem(at: destination.appendingPathComponent(Self.allPaths[0]))
        let others = Array(Self.allPaths.dropFirst())
        let before = try Self.identities(others, at: destination)

        let resumed = try await Self.resume(fixtures, source: source, destination: destination, from: parent)

        for spec in EngineHarness.standardFiles {
            #expect(resumed.report.outcome(spec.path, at: destination) == .transferredPendingVerification)
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(Self.copiedBytes(resumed) == Int64(EngineHarness.standardFiles[0].size))
        #expect(try Self.identities(others, at: destination) == before)
        #expect(resumed.report.status == .transferredPendingVerification)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    struct ProfilePair: Sendable, CustomTestStringConvertible {
        let resume: VerificationProfile
        let parentRecorded: String?
        var testDescription: String {
            "\(resume.rawValue) resume of a parent recorded as \(parentRecorded ?? "nil")"
        }
    }

    static let refusedProfilePairs: [ProfilePair] = [
        ProfilePair(resume: .standard, parentRecorded: "fast"),
        ProfilePair(resume: .maximum, parentRecorded: "fast"),
        ProfilePair(resume: .fast, parentRecorded: "standard"),
        ProfilePair(resume: .fast, parentRecorded: nil),
    ]

    /// A Standard or Maximum resume owes a read-back of every copy; it may not
    /// inherit unread pairs, and it never overwrites them. AppModel.resume
    /// always keeps the parent's profile, so this is a guard, not a user path.
    @Test(arguments: refusedProfilePairs)
    func pendingPairsCarryForwardOnlyFromFastToFast(_ pair: ProfilePair) async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        var parent = try await Self.fullyTransferredFastParent(fixtures, source: source, destination: destination)
        parent.verificationProfile = pair.parentRecorded
        let before = try Self.identities(Self.allPaths, at: destination)

        let resumed = try await Self.resume(
            fixtures, source: source, destination: destination, from: parent, profile: pair.resume)

        for spec in EngineHarness.standardFiles {
            #expect(resumed.report.outcome(spec.path, at: destination) == .failed(.nameCollision))
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(resumed.report.verifiedCount == 0)
        #expect(resumed.report.pendingVerificationCount == 0)
        #expect(resumed.report.status == .failed)
        #expect(try Self.identities(Self.allPaths, at: destination) == before)
        #expect(Self.copiedBytes(resumed) == 0)
        #expect(Self.engineLeftovers(in: destination).isEmpty)
    }

    // MARK: - Pause log

    /// engine-safety-correctness-5: Fast never reads a copy back, so its pause
    /// must not say the completed files were verified. Standard reads back
    /// what it copied before it pauses and keeps its wording.
    @Test(arguments: [VerificationProfile.fast, .standard])
    func pauseLogSaysWhatTheCompletedFilesActuallyAre(_ profile: VerificationProfile) async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        // Timed like pausedFastRun: the pause lands while the first file is mid-copy.
        let fileSystem = FailpointFileSystem(base: RealFileSystem())
        fileSystem.delayReads(microseconds: 500)
        fileSystem.delayWrites(microseconds: 500)

        let paused = try await EngineHarness.run(
            fileSystem: fileSystem,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("pause-spool"),
            verificationProfile: profile,
            chunkSize: 4 * 1024,
            pauseWhen: { event in
                if case .progress(let progress) = event { return progress.copiedBytes > 32 * 1024 }
                return false
            }
        )

        try #require(paused.report.status == .paused)
        try #require(paused.report.failedCount == 0)
        let pauseLines = paused.logMessages.filter { $0.hasPrefix("Transfer paused safely") }
        if profile == .fast {
            try #require(paused.report.pendingVerificationCount > 0)
            #expect(paused.report.verifiedCount == 0)
            #expect(pauseLines == [
                "Transfer paused safely; completed files were transferred and recorded "
                    + "but still need independent verification",
            ])
            #expect(!paused.logMessages.contains { $0.contains("verified and recorded") })
        } else {
            try #require(paused.report.verifiedCount > 0)
            #expect(pauseLines == ["Transfer paused safely; completed files were verified and recorded"])
        }
    }
}
