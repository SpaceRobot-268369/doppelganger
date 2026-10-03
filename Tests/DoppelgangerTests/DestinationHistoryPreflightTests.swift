import Foundation
import Testing
@testable import Doppelganger

/// engine-2 / verify-evidence-3: an offload into an existing folder appends
/// its ASC MHL generation to the history already there, and
/// `MHLHistoryStore` refuses one that history contradicts only after every
/// copy verified. Preflight foresees those refusals before any byte moves,
/// through the same loader and the same `HistoryBaseline` as the engine.
///
/// The agreement tests build each history with the real engine and then run
/// both preflight and the engine against it: preflight must block exactly
/// what the engine fails, and warn where the engine fails only if the bytes
/// differ.
///
/// Synthetic fixtures in a temp directory only (AGENTS.md Principle 3).
struct DestinationHistoryPreflightTests {
    private static let clip = "DCIM/100/C0001.MP4"
    private static let digest = "0123456789abcdef"
    private static let otherDigest = "1111111111111111"
    /// A source timestamp with a fraction, as APFS reports one.
    private static let time: TimeInterval = 1_790_000_000.25

    /// How `MHLWriter.generation` writes `lastmodificationdate`.
    private static func stamp(_ time: TimeInterval) -> String {
        Date(timeIntervalSince1970: time).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// One `<hash>` record of an earlier generation. A nil `action` is an
    /// unannotated record, as older writers made; `alongside` adds more hash
    /// elements to the same record.
    private static func hashXML(
        _ path: String = clip,
        size: Int64 = 70_000,
        tag: String = "xxh3",
        digest: String = digest,
        action: String? = "original",
        modifiedAt: String? = nil,
        alongside: String = ""
    ) -> String {
        let modified = modifiedAt.map { " lastmodificationdate=\"\($0)\"" } ?? ""
        let annotation = action.map { " action=\"\($0)\"" } ?? ""
        return """
                <hash>
                  <path size="\(size)"\(modified)>\(path)</path>
                  <\(tag)\(annotation) hashdate="2026-10-01T12:00:00+00:00">\(digest)</\(tag)>\(alongside)
                </hash>
            """
    }

    private static func generationXML(_ hashes: [String]) -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
              <hashes>
            \(hashes.joined(separator: "\n"))
              </hashes>
            </hashlist>
            """.utf8)
    }

    /// One earlier generation's record, read back through `MHLReader`.
    private static func record(
        _ path: String = clip,
        size: Int64 = 70_000,
        tag: String = "xxh3",
        digest: String = digest,
        action: String? = "original",
        modifiedAt: String? = nil,
        alongside: String = ""
    ) throws -> MHLDocument.Entry {
        let hash = hashXML(
            path, size: size, tag: tag, digest: digest, action: action, modifiedAt: modifiedAt, alongside: alongside)
        return try #require(try MHLReader.read(generationXML([hash])).entries.first)
    }

    /// Appends one generation holding `hashes` to `folder`'s ASC MHL chain,
    /// written by hand as an older build or another tool might have.
    private static func appendGeneration(_ hashes: [String], to folder: URL) throws {
        let directory = folder.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        let prior: [MHLWriter.ChainEntry] = try FileManager.default.fileExists(atPath: chainURL.path)
            ? MHLReader.readChain(Data(contentsOf: chainURL)).entries.map {
                MHLWriter.ChainEntry(sequence: $0.sequence, path: $0.path, c4: $0.c4)
            }
            : []
        let sequence = prior.count + 1
        let name = String(format: "%04d_by_hand.mhl", sequence)
        let data = generationXML(hashes)
        try data.write(to: directory.appendingPathComponent(name))
        let entry = MHLWriter.ChainEntry(sequence: sequence, path: name, c4: C4Checksum.digest(data))
        try Data(MHLWriter.chainXML(entries: prior + [entry]).utf8).write(to: chainURL)
    }

    private static func item(size: Int64 = 70_000, time: TimeInterval? = Self.time) -> SourceItem {
        SourceItem(relativePath: clip, size: size, modificationTime: time)
    }

    private static func predict(
        _ history: [MHLDocument.Entry],
        _ item: SourceItem = item(),
        algorithm: ChecksumAlgorithm = .xxh3
    ) -> HistoryBaseline.Prediction? {
        HistoryBaseline(history, algorithm: algorithm).prediction(for: item)
    }

    // MARK: - Prediction

    @Test func noHistoryPredictsNothing() {
        #expect(Self.predict([]) == nil)
    }

    /// Same size and time: most likely the same file, so only the digest can
    /// tell, and a matching one is "verified".
    @Test func theSameFileAtItsRecordedSizeAndTimePredictsNothing() throws {
        let history = [try Self.record(modifiedAt: Self.stamp(Self.time))]
        #expect(Self.predict(history) == nil)
        #expect(try HistoryBaseline(history, algorithm: .xxh3).action(for: Self.clip, digest: Self.digest) == "verified")
    }

    /// A hash in this format for a file of another size cannot equal the new
    /// file's, so `action` refuses it whatever the bytes.
    @Test func aDifferentSizeIsACertainConflict() throws {
        let history = [try Self.record(size: 60_000, modifiedAt: Self.stamp(Self.time))]
        #expect(Self.predict(history) == .differentFile)
        #expect(throws: MHLHistoryError.conflictingHistory(path: Self.clip)) {
            try HistoryBaseline(history, algorithm: .xxh3).action(for: Self.clip, digest: Self.otherDigest)
        }
    }

    /// An original this run's format cannot compare: `action` refuses every
    /// digest, and the prediction names the formats the folder does hold.
    @Test func anOriginalOnlyInAnotherFormatIsACertainConflict() throws {
        let history = [
            try Self.record(size: 60_000, tag: "xxh64", action: "original"),
            try Self.record(tag: "md5", digest: "900150983cd24fb0d6963f7d28e17f72", action: "verified"),
        ]
        #expect(Self.predict(history) == .otherFormat(recorded: [.xxh64, .md5]))
        for digest in [Self.digest, Self.otherDigest] {
            #expect(throws: MHLHistoryError.conflictingHistory(path: Self.clip)) {
                try HistoryBaseline(history, algorithm: .xxh3).action(for: Self.clip, digest: digest)
            }
        }
    }

    /// A record marked "failed", or with an action ASC MHL does not define,
    /// is no baseline for the prediction either.
    @Test func anUntrustedRecordIsIgnored() throws {
        let trusted = try Self.record(modifiedAt: Self.stamp(Self.time))
        for action in ["failed", "rehashed"] {
            let untrusted = try Self.record(size: 10, digest: Self.otherDigest, action: action)
            #expect(Self.predict([untrusted]) == nil, "\(action)")
            #expect(Self.predict([trusted, untrusted]) == nil, "\(action)")
            // An original in another format, tainted by the record's other
            // hash: trusted, it would be one this format cannot compare.
            let tainted = try Self.record(
                tag: "xxh64",
                action: "original",
                alongside: "<md5 action=\"\(action)\">900150983cd24fb0d6963f7d28e17f72</md5>"
            )
            #expect(Self.predict([tainted]) == nil, "\(action)")
            #expect(try HistoryBaseline([tainted], algorithm: .xxh3).action(for: Self.clip, digest: Self.digest)
                == "original")
        }
    }

    /// Only this format's hashes are compared, so only their records' size
    /// and time describe the file `action` compares against.
    @Test func onlyRecordsInThisFormatDecideSizeAndTime() throws {
        // An older build's hash in another format for an earlier, smaller
        // file, then this format's original for the current one.
        let earlier = try Self.record(
            size: 60_000, tag: "xxh64", action: "verified", modifiedAt: Self.stamp(Self.time - 86_400))
        let current = try Self.record(modifiedAt: Self.stamp(Self.time))
        #expect(Self.predict([earlier, current]) == nil)
        #expect(try HistoryBaseline([earlier, current], algorithm: .xxh3).action(for: Self.clip, digest: Self.digest)
            == "verified")
        // Another format's record at the file's size and time vouches for no
        // hash this format compares.
        let elsewhere = try Self.record(modifiedAt: Self.stamp(Self.time - 3_600))
        let otherFormat = try Self.record(tag: "xxh64", action: "verified", modifiedAt: Self.stamp(Self.time))
        #expect(Self.predict([elsewhere, otherFormat]) == .probablyDifferentFile)
    }

    /// Two different hashes in this format for one path, or one no hasher
    /// writes, can never all equal the new file's: `action` refuses every
    /// digest, whatever the file's size and time.
    @Test func aContradictoryOrMalformedHashIsACertainConflict() throws {
        let contradictory = [
            try Self.record(modifiedAt: Self.stamp(Self.time)),
            try Self.record(digest: Self.otherDigest, action: "verified", modifiedAt: Self.stamp(Self.time)),
        ]
        let malformed = [try Self.record(digest: "c0ffee", modifiedAt: Self.stamp(Self.time))]
        for history in [contradictory, malformed] {
            #expect(Self.predict(history) == .differentFile)
            for digest in [Self.digest, Self.otherDigest] {
                #expect(throws: MHLHistoryError.conflictingHistory(path: Self.clip)) {
                    try HistoryBaseline(history, algorithm: .xxh3).action(for: Self.clip, digest: digest)
                }
            }
        }
        // One hash recorded twice, or in capitals, is no contradiction.
        let again = [
            try Self.record(modifiedAt: Self.stamp(Self.time)),
            try Self.record(digest: Self.digest.uppercased(), action: "verified", modifiedAt: Self.stamp(Self.time)),
        ]
        #expect(Self.predict(again) == nil)
        #expect(try HistoryBaseline(again, algorithm: .xxh3).action(for: Self.clip, digest: Self.digest) == "verified")
    }

    /// Histories from older builds hold only "verified" or unannotated
    /// records. In another format, `action` makes this run's hash the
    /// path's first original, so nothing conflicts.
    @Test func anOlderWritersRecordInAnotherFormatIsNoConflict() throws {
        for action in ["verified", nil] {
            let history = [try Self.record(size: 60_000, tag: "xxh64", action: action)]
            #expect(Self.predict(history) == nil, "\(action ?? "unannotated")")
            #expect(try HistoryBaseline(history, algorithm: .xxh3).action(for: Self.clip, digest: Self.digest)
                == "original")
        }
    }

    /// Same size, but every recorded time is more than FAT's 2-second
    /// granularity away from the file's.
    @Test func aDifferentTimeAtTheSameSizeIsAProbableConflict() throws {
        let history = [try Self.record(modifiedAt: Self.stamp(Self.time))]
        #expect(Self.predict(history, Self.item(time: Self.time + 3)) == .probablyDifferentFile)
        #expect(Self.predict(history, Self.item(time: Self.time - 3_600)) == .probablyDifferentFile)
        // Within FAT's 2-second granularity: the same file, rounded.
        #expect(Self.predict(history, Self.item(time: Self.time + 1.5)) == nil)
        #expect(Self.predict(history, Self.item(time: Self.time - 2)) == nil)
        // One record at the file's time is enough.
        let again = try Self.record(modifiedAt: Self.stamp(Self.time + 3_600))
        #expect(Self.predict(history + [again], Self.item(time: Self.time + 3_600)) == nil)
    }

    @Test func aMissingOrUnparseableTimePredictsNothing() throws {
        #expect(Self.predict([try Self.record(modifiedAt: nil)], Self.item(time: Self.time + 3_600)) == nil)
        #expect(Self.predict([try Self.record(modifiedAt: "yesterday")], Self.item(time: Self.time + 3_600)) == nil)
        #expect(Self.predict([try Self.record(modifiedAt: Self.stamp(Self.time))], Self.item(time: nil)) == nil)
    }

    /// The time comparison reads exactly what the writer records: the source
    /// item's own time, through `MHLHistoryStore`'s loader.
    @Test func theRecordedTimeIsTheSourceItemsAsTheWriterFormatsIt() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "RAID")
        let report = TransferReport(
            id: UUID(),
            status: .verified,
            algorithm: .xxh3,
            sourceRoot: ReportFixtures.source,
            destinations: [destination],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: [ItemResult(item: Self.item(), sourceDigest: Self.digest, outcomes: [destination: .verified])],
            manifestLocations: [destination]
        )
        _ = try #require(try MHLHistoryStore.append(report: report, destination: destination, fileSystem: RealFileSystem()))

        let history = try #require(try MHLHistoryStore.loadHistory(at: destination, fileSystem: RealFileSystem()))
        #expect(history.records.map(\.modifiedAt) == [Self.stamp(Self.time)])
        #expect(Self.predict(history.records) == nil)
        #expect(Self.predict(history.records, Self.item(time: Self.time + 3)) == .probablyDifferentFile)
        #expect(Self.predict(history.records, Self.item(size: 1)) == .differentFile)
        #expect(Self.predict(history.records, algorithm: .md5) == .otherFormat(recorded: [.xxh3]))
    }

    @Test func aFolderWithoutAChainHasNoHistory() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "RAID")
        #expect(try MHLHistoryStore.loadHistory(at: destination, fileSystem: RealFileSystem()) == nil)
    }

    // MARK: - Engine agreement

    private static let cardA: [FixtureBuilder.FileSpec] = [
        // Multi-chunk at the 64 KiB test chunk size, like a real clip.
        FixtureBuilder.FileSpec(clip, size: 70_000, seed: 71),
    ]

    private struct Offload {
        let preflight: TransferPreflight
        let report: TransferReport

        /// The preflight messages about the folder's ASC MHL history; the
        /// fixtures share one volume, so independence warnings are expected.
        var historyBlocking: [String] { preflight.blockingIssues.filter { $0.contains("ASC MHL history") } }
        var historyWarnings: [String] { preflight.warnings.filter { $0.contains("ASC MHL history") } }
        var failedOnItsMHLRecord: Bool {
            report.status == .failed
                && report.issues.contains { $0.contains("Could not write a complete ASC MHL generation") }
        }
    }

    /// Preflight, then the engine started exactly as `TransferSession.start()`
    /// starts a reviewed plan — whatever preflight said, so the two verdicts
    /// can be compared.
    private static func offload(
        _ source: URL,
        into base: URL,
        algorithm: ChecksumAlgorithm,
        layout: DestinationLayout = .directly,
        folderName: String = "",
        includedRelativePaths: Set<String>? = nil,
        spool: URL
    ) async throws -> Offload {
        let preflight = await TransferPreflight.inspect(
            source: source,
            destinationBases: [base],
            folderName: folderName,
            algorithm: algorithm,
            layout: layout,
            includedRelativePaths: includedRelativePaths
        )
        let duplicateManifests = Dictionary(uniqueKeysWithValues: preflight.destinations.compactMap { destination in
            destination.duplicateManifest.map { (destination.output.path, $0) }
        })
        let request = TransferRequest(
            sourceRoot: preflight.source,
            destinations: preflight.requestDestinations,
            algorithm: algorithm,
            verificationProfile: .standard,
            sourceFingerprint: preflight.sourceFingerprint,
            spoolDirectory: spool,
            allowSameVolume: true, // fixtures share the temp volume
            requireNewOutputRoots: duplicateManifests.isEmpty,
            includedRelativePaths: preflight.includedRelativePaths,
            duplicateManifests: duplicateManifests
        )
        let engine = TransferEngine(
            fileSystem: RealFileSystem(),
            configuration: TransferConfiguration(chunkSize: 64 * 1024, progressInterval: .milliseconds(1))
        )
        var report: TransferReport?
        for await event in await engine.run(request) {
            if case .finished(let finished) = event { report = finished }
        }
        return Offload(preflight: preflight, report: try #require(report, "stream must end with .finished"))
    }

    private struct World {
        let fixtures: FixtureBuilder
        let cardA: URL
        let base: URL
        var spool: URL { fixtures.root.appendingPathComponent("spool", isDirectory: true) }
        var history: URL { base.appendingPathComponent(MHLWriter.directoryName, isDirectory: true) }
    }

    /// Card A offloaded directly into /RAID, then its clip moved out of the
    /// folder (scratch fixture only): the folder's history still records it.
    private static func historyOfCardA(algorithm: ChecksumAlgorithm = .xxh3) async throws -> World {
        let fixtures = try FixtureBuilder()
        let world = World(
            fixtures: fixtures,
            cardA: try fixtures.makeCard(named: "A", files: cardA),
            base: try fixtures.makeDestination(named: "RAID")
        )
        let first = try await offload(world.cardA, into: world.base, algorithm: algorithm, spool: world.spool)
        #expect(first.preflight.canStart, "\(first.preflight.blockingIssues)")
        #expect(first.historyWarnings.isEmpty)
        #expect(first.report.status == .verified, "issues: \(first.report.issues)")
        try FileManager.default.removeItem(at: world.base.appendingPathComponent(clip))
        return world
    }

    /// The reported problem: another card's C0001 goes direct into the same
    /// folder. The copy verifies, and the MHL append fails it; preflight now
    /// blocks it first.
    @Test func anotherCardsDifferentSizeClipIsBlockedAndTheEngineFailsIt() async throws {
        let world = try await Self.historyOfCardA()
        let cardB = try world.fixtures.makeCard(named: "B", files: [
            FixtureBuilder.FileSpec(Self.clip, size: 60_000, seed: 81),
        ])

        let second = try await Self.offload(cardB, into: world.base, algorithm: .xxh3, spool: world.spool)

        #expect(!second.preflight.canStart)
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID already records a different file at 1 planned path(s): \(Self.clip). "
                + "This offload could not add its MHL record; choose a new folder.",
        ])
        #expect(second.historyWarnings.isEmpty)
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
        #expect(second.report.issues.contains {
            $0.contains("ASC MHL history already records a different or incomparable hash for \(Self.clip)")
        })
        // Every pair verified, which is why a retry finds nothing to repair.
        #expect(second.report.outcome(Self.clip, at: world.base) == .verified)
    }

    /// Control: the identical card again, after its clip moved out, under the
    /// checksum type the folder uses. Nothing to block or warn about, and the
    /// engine records "verified".
    @Test(arguments: [ChecksumAlgorithm.xxh3, .xxh64])
    func theSameCardAgainIsNeitherBlockedNorWarnedAndVerifies(algorithm: ChecksumAlgorithm) async throws {
        let world = try await Self.historyOfCardA(algorithm: algorithm)

        let second = try await Self.offload(world.cardA, into: world.base, algorithm: algorithm, spool: world.spool)

        #expect(second.preflight.canStart, "\(second.preflight.blockingIssues)")
        #expect(second.historyBlocking.isEmpty)
        #expect(second.historyWarnings.isEmpty)
        #expect(second.report.status == .verified, "issues: \(second.report.issues)")
    }

    /// The same clips under another checksum type, either way round: the
    /// history's original cannot be compared, so the engine refuses the
    /// generation, and preflight names the type the folder holds.
    @Test(arguments: zip([ChecksumAlgorithm.xxh64, .xxh3], [ChecksumAlgorithm.xxh3, .md5]))
    func theSameCardUnderAnotherChecksumTypeIsBlockedAndTheEngineFailsIt(
        recorded: ChecksumAlgorithm,
        algorithm: ChecksumAlgorithm
    ) async throws {
        let world = try await Self.historyOfCardA(algorithm: recorded)

        let second = try await Self.offload(world.cardA, into: world.base, algorithm: algorithm, spool: world.spool)

        #expect(!second.preflight.canStart)
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID already records 1 planned path(s) only under another checksum type, "
                + "\(recorded.displayName): \(Self.clip). This offload could not add its MHL record; use the "
                + "checksum type the folder already uses, or choose a new folder.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
        #expect(second.report.outcome(Self.clip, at: world.base) == .verified)
    }

    /// Clips recorded under different checksum types: whichever of them this
    /// offload used, one clip would still have only an original it cannot
    /// compare, so preflight leaves only a new folder.
    @Test func clipsRecordedUnderDifferentTypesLeaveOnlyANewFolder() async throws {
        let world = try await Self.historyOfCardA(algorithm: .xxh64)
        let other = FixtureBuilder.FileSpec("DCIM/100/C0002.MP4", size: 3_000, seed: 83)
        let cardB = try world.fixtures.makeCard(named: "B", files: [other])
        let first = try await Self.offload(cardB, into: world.base, algorithm: .md5, spool: world.spool)
        #expect(first.report.status == .verified, "issues: \(first.report.issues)")
        try FileManager.default.removeItem(at: world.base.appendingPathComponent(other.path))
        let both = try world.fixtures.makeCard(named: "AB", files: Self.cardA + [other])

        let second = try await Self.offload(both, into: world.base, algorithm: .xxh3, spool: world.spool)

        #expect(!second.preflight.canStart)
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID already records 2 planned path(s) only under another checksum type, "
                + ListFormatter.localizedString(byJoining: ["MD5", "XXH64BE"])
                + ": \(Self.clip), \(other.path). It mixes checksum types, so no single type matches "
                + "every planned path. This offload could not add its MHL record; choose a new folder.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
    }

    /// Where one of the folder's types does cover every planned path, the
    /// advice names that type only, and under it the same baseline finds
    /// nothing to refuse.
    @Test func theAdviceNamesOnlyATypeThatCoversEveryPlannedPath() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "RAID")
        let md5 = "900150983cd24fb0d6963f7d28e17f72"
        let other = "DCIM/100/C0002.MP4"
        try Self.appendGeneration([
            Self.hashXML(tag: "xxh64", alongside: "<md5 action=\"original\">\(md5)</md5>"),
            Self.hashXML(other, size: 3_000, tag: "md5", digest: md5),
        ], to: destination)
        let items = [Self.item(), SourceItem(relativePath: other, size: 3_000)]
        func issues(_ algorithm: ChecksumAlgorithm) -> [String] {
            TransferPreflight.historyIssues(
                base: destination, output: destination, items: items, algorithm: algorithm, fileSystem: RealFileSystem()
            ).blocking
        }

        #expect(issues(.xxh3) == [
            "The ASC MHL history in RAID already records 2 planned path(s) only under another checksum type, "
                + "MD5: \(Self.clip), \(other). This offload could not add its MHL record; use the checksum type "
                + "the folder already uses, or choose a new folder.",
        ])
        #expect(issues(.md5).isEmpty)
    }

    /// A history that already holds two different hashes for the clip, as a
    /// build from between direct layout and the history check could append,
    /// or another tool can: no file matches both, so the engine refuses even
    /// the identical card, and preflight blocks it.
    @Test func aHistoryThatContradictsItselfIsBlockedAndTheEngineFailsEvenTheSameCard() async throws {
        let world = try await Self.historyOfCardA()
        let recorded = try #require(
            try MHLHistoryStore.loadHistory(at: world.base, fileSystem: RealFileSystem())?.records.first)
        let modifiedAt = try #require(recorded.modifiedAt)
        try Self.appendGeneration([
            Self.hashXML(size: recorded.size, digest: Self.otherDigest, action: "verified", modifiedAt: modifiedAt),
        ], to: world.base)

        let second = try await Self.offload(world.cardA, into: world.base, algorithm: .xxh3, spool: world.spool)

        #expect(!second.preflight.canStart)
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID already records a different file at 1 planned path(s): \(Self.clip). "
                + "This offload could not add its MHL record; choose a new folder.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
        #expect(second.report.outcome(Self.clip, at: world.base) == .verified)
    }

    enum Damage: String, CaseIterable, Sendable {
        case tamperedGeneration, missingGeneration, malformedChain
    }

    /// A history the loader cannot read: preflight blocks, and the engine,
    /// reading it the same way, fails the transfer after the copy.
    @Test(arguments: Damage.allCases)
    func anUnreadableHistoryIsBlockedAndTheEngineFailsIt(damage: Damage) async throws {
        let world = try await Self.historyOfCardA()
        let chainURL = world.history.appendingPathComponent(MHLWriter.chainFileName)
        let generation = try #require(try MHLReader.readChain(Data(contentsOf: chainURL)).entries.first?.path)
        let generationURL = world.history.appendingPathComponent(generation)
        switch damage {
        case .tamperedGeneration:
            let handle = try FileHandle(forWritingTo: generationURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("<!-- edited -->\n".utf8))
            try handle.close()
        case .missingGeneration:
            try FileManager.default.removeItem(at: generationURL)
        case .malformedChain:
            try Data("not a chain".utf8).write(to: chainURL)
        }

        let second = try await Self.offload(world.cardA, into: world.base, algorithm: .xxh3, spool: world.spool)

        let reason = damage == .tamperedGeneration
            ? "\(generation) no longer matches the checksum its chain recorded"
            : "its chain or a generation is missing, unreadable, or malformed"
        #expect(!second.preflight.canStart)
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID cannot be read: \(reason). "
                + "This offload could not add its MHL record there; choose another folder.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
    }

    /// Same size, another time, other bytes: preflight cannot prove the
    /// conflict without hashing, so it warns, and the engine shows why.
    @Test func aSameSizeClipFromAnotherTimeIsWarnedAndTheEngineFailsItsOtherBytes() async throws {
        let world = try await Self.historyOfCardA()
        let cardB = try world.fixtures.makeCard(named: "B", files: [
            FixtureBuilder.FileSpec(Self.clip, size: 70_000, seed: 82),
        ])
        let recorded = try #require(
            try FileManager.default.attributesOfItem(atPath: world.cardA.appendingPathComponent(Self.clip).path)[.modificationDate] as? Date
        )
        try FileManager.default.setAttributes(
            [.modificationDate: recorded.addingTimeInterval(-3_600)],
            ofItemAtPath: cardB.appendingPathComponent(Self.clip).path
        )

        let second = try await Self.offload(cardB, into: world.base, algorithm: .xxh3, spool: world.spool)

        #expect(second.preflight.canStart, "\(second.preflight.blockingIssues)")
        #expect(second.historyBlocking.isEmpty)
        #expect(second.historyWarnings == [
            "The ASC MHL history in RAID records 1 planned path(s) at the same size but a different "
                + "modification time: \(Self.clip). If the contents differ, this offload will fail when it "
                + "writes its MHL record.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
        #expect(second.report.outcome(Self.clip, at: world.base) == .verified)
    }

    /// A history warning needs acknowledging like any warning, but it is
    /// never consent to copies on one device: that comes only from an
    /// independence warning. Source and RAID get separate synthetic devices
    /// here, so the history warning is the only one.
    @Test func aHistoryWarningIsNoConsentToShareADevice() async throws {
        let world = try await Self.historyOfCardA()
        let cardB = try world.fixtures.makeCard(named: "B", files: [
            FixtureBuilder.FileSpec(Self.clip, size: 70_000, seed: 82),
        ])
        let recorded = try #require(
            try FileManager.default.attributesOfItem(atPath: world.cardA.appendingPathComponent(Self.clip).path)[.modificationDate] as? Date
        )
        try FileManager.default.setAttributes(
            [.modificationDate: recorded.addingTimeInterval(-3_600)],
            ofItemAtPath: cardB.appendingPathComponent(Self.clip).path
        )
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.overrideVolume(at: cardB, with: FileSystemVolume(
            identifier: "card-b", name: "B", mountPath: cardB.path, physicalDeviceIdentifier: "disk:disk4@11"
        ))
        fs.overrideVolume(at: world.base, with: FileSystemVolume(
            identifier: "raid", name: "RAID", mountPath: world.base.path, physicalDeviceIdentifier: "disk:disk6@42"
        ))

        let preflight = await TransferPreflight.inspect(
            source: cardB,
            destinationBases: [world.base],
            folderName: "",
            algorithm: .xxh3,
            layout: .directly,
            fileSystem: fs
        )

        #expect(preflight.canStart, "\(preflight.blockingIssues)")
        #expect(preflight.warnings.count == 1 && preflight.warnings[0].contains("ASC MHL history"), "\(preflight.warnings)")
        #expect(preflight.sameDeviceWarnings.isEmpty)
        #expect(preflight.requiresAcknowledgement)
        #expect(!preflight.allowsSameDevice(acknowledged: true))
    }

    /// Only the planned items count: a selection that leaves the conflicting
    /// clip on the card is neither blocked nor failed.
    @Test func aSelectionWithoutTheConflictingClipIsNotBlockedAndVerifies() async throws {
        let world = try await Self.historyOfCardA()
        let other = "DCIM/100/C0002.MP4"
        let cardB = try world.fixtures.makeCard(named: "B", files: [
            FixtureBuilder.FileSpec(Self.clip, size: 60_000, seed: 81),
            FixtureBuilder.FileSpec(other, size: 3_000, seed: 83),
        ])

        let second = try await Self.offload(
            cardB, into: world.base, algorithm: .xxh3, includedRelativePaths: [other], spool: world.spool)

        #expect(second.preflight.canStart, "\(second.preflight.blockingIssues)")
        #expect(second.historyBlocking.isEmpty)
        #expect(second.report.status == .verified, "issues: \(second.report.issues)")
    }

    /// A new folder that exists because it holds a verified duplicate gets
    /// the engine's history append too, so it gets the same check.
    @Test func aVerifiedDuplicateFolderGetsTheSameHistoryCheck() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(named: "A", files: Self.cardA)
        let base = try fixtures.makeDestination(named: "RAID")
        let spool = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let first = try await Self.offload(
            card, into: base, algorithm: .xxh3, layout: .newFolder, folderName: "20261004_A001", spool: spool)
        #expect(first.report.status == .verified, "issues: \(first.report.issues)")
        let output = base.appendingPathComponent("20261004_A001", isDirectory: true)
        try Data("not a chain".utf8).write(to: output
            .appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
            .appendingPathComponent(MHLWriter.chainFileName))

        let second = try await Self.offload(
            card, into: base, algorithm: .xxh3, layout: .newFolder, folderName: "20261004_A001", spool: spool)

        #expect(second.preflight.destinations.first?.duplicateManifest != nil)
        #expect(!second.preflight.canStart)
        // Named by the folder whose history it is, not the destination.
        #expect(second.historyBlocking == [
            "The ASC MHL history in RAID/20261004_A001 cannot be read: its chain or a generation is missing, "
                + "unreadable, or malformed. This offload could not add its MHL record there; choose another folder.",
        ])
        #expect(second.failedOnItsMHLRecord, "issues: \(second.report.issues)")
    }

    // MARK: - Messages

    /// Up to three paths are named, sorted, and the count covers them all.
    @Test func aLongConflictNamesThreePathsAndCountsThemAll() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "RAID")
        let paths = (1...5).map { String(format: "DCIM/100/C%04d.MP4", $0) }
        let report = TransferReport(
            id: UUID(),
            status: .verified,
            algorithm: .xxh3,
            sourceRoot: ReportFixtures.source,
            destinations: [destination],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: paths.map {
                ItemResult(item: SourceItem(relativePath: $0, size: 10), sourceDigest: Self.digest, outcomes: [destination: .verified])
            },
            manifestLocations: [destination]
        )
        _ = try #require(try MHLHistoryStore.append(report: report, destination: destination, fileSystem: RealFileSystem()))

        let issues = TransferPreflight.historyIssues(
            base: destination,
            output: destination,
            items: paths.reversed().map { SourceItem(relativePath: $0, size: 11) },
            algorithm: .xxh3,
            fileSystem: RealFileSystem()
        )

        #expect(issues.blocking == [
            "The ASC MHL history in RAID already records a different file at 5 planned path(s): "
                + "DCIM/100/C0001.MP4, DCIM/100/C0002.MP4, DCIM/100/C0003.MP4 …and 2 more. "
                + "This offload could not add its MHL record; choose a new folder.",
        ])
        #expect(issues.warnings.isEmpty)
    }

    /// Each message's Simplified Chinese entry formats with the same
    /// arguments and shows every one of them.
    @Test func historyMessagesFormatInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let messages: [(key: String, arguments: [any CVarArg], shown: [String])] = [
            (
                "The ASC MHL history in %@ cannot be read: %@. This offload could not add its MHL record there; choose another folder.",
                ["RAID", "REASON"], ["RAID", "REASON"]
            ),
            ("%@ no longer matches the checksum its chain recorded", ["0001_RAID.mhl"], ["0001_RAID.mhl"]),
            ("its chain or a generation is missing, unreadable, or malformed", [], []),
            (
                "The ASC MHL history in %@ already records a different file at %lld planned path(s): %@. This offload could not add its MHL record; choose a new folder.",
                ["RAID", Int64(7), "PATHS"], ["RAID", "7", "PATHS"]
            ),
            (
                "The ASC MHL history in %@ already records %lld planned path(s) only under another checksum type, %@: %@. This offload could not add its MHL record; use the checksum type the folder already uses, or choose a new folder.",
                ["RAID", Int64(7), "XXH64BE", "PATHS"], ["RAID", "7", "XXH64BE", "PATHS"]
            ),
            (
                "The ASC MHL history in %@ already records %lld planned path(s) only under another checksum type, %@: %@. It mixes checksum types, so no single type matches every planned path. This offload could not add its MHL record; choose a new folder.",
                ["RAID", Int64(7), "MD5 and XXH64BE", "PATHS"], ["RAID", "7", "MD5 and XXH64BE", "PATHS"]
            ),
            (
                "The ASC MHL history in %@ records %lld planned path(s) at the same size but a different modification time: %@. If the contents differ, this offload will fail when it writes its MHL record.",
                ["RAID", Int64(7), "PATHS"], ["RAID", "7", "PATHS"]
            ),
        ]
        for message in messages {
            let translation = try #require(catalog[message.key], "no zh-Hans entry for \(message.key)")
            #expect(translation != message.key)
            let formatted = String(format: translation, locale: Locale(identifier: "zh-Hans"), arguments: message.arguments)
            for argument in message.shown {
                #expect(formatted.contains(argument), "\(message.key) → \(formatted)")
            }
        }
    }
}
