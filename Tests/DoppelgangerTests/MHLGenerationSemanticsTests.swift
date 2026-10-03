import Foundation
import Testing
@testable import Doppelganger

/// verify-evidence-3, -4: a path's first sighting in a folder's ASC MHL
/// history is "original" and a matching re-check is "verified", and a root or
/// directory hash is written only where a generation describes everything
/// beneath it, with the values the reference ascmhl computes. A hash read back
/// from a manifest is recorded only when it is a well-formed digest.
///
/// Synthetic fixtures in a temp directory only (AGENTS.md Principle 3).
struct MHLGenerationSemanticsTests {
    // MARK: - Helpers

    private static func xxh64(_ bytes: [UInt8]) -> String {
        var hasher = ChecksumAlgorithm.xxh64.makeHasher()
        hasher.update(bytes, count: bytes.count)
        return hasher.hexDigest()
    }

    /// Every generation of `folder`'s validated chain, oldest first.
    private static func generations(in folder: URL) throws -> [(xml: String, document: MHLDocument)] {
        let history = folder.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        return try MHLReader.validateChain(at: history).entries.map { entry in
            let data = try Data(contentsOf: history.appendingPathComponent(entry.path))
            return (String(decoding: data, as: UTF8.self), try MHLReader.read(data))
        }
    }

    /// path → action of each xxh64 `<hash>`, read from the XML so the tests do
    /// not depend on how `MHLReader` models actions.
    private static func actions(in xml: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in xml.matches(of: #/<path size="\d+"[^>]*>([^<]+)</path>\s*<xxh64 action="(\w+)"/#) {
            result[String(match.1)] = String(match.2)
        }
        return result
    }

    /// path → hashdate of each xxh64 `<hash>`.
    private static func hashDates(in xml: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in xml.matches(of: #/<path size="\d+"[^>]*>([^<]+)</path>\s*<xxh64 action="\w+" hashdate="([^"]+)"/#) {
            result[String(match.1)] = String(match.2)
        }
        return result
    }

    private static func allOriginal(_ specs: [FixtureBuilder.FileSpec]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: specs.map { ($0.path, "original") })
    }

    /// One earlier generation's record for `path`, read back through
    /// `MHLReader` so the tests do not depend on how `MHLDocument.Entry`
    /// models hash actions.
    private static func historyEntry(
        _ path: String,
        tag: String = "xxh64",
        digest: String,
        action: String
    ) throws -> MHLDocument.Entry {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
              <hashes>
                <hash>
                  <path size="10">\(path)</path>
                  <\(tag) action="\(action)" hashdate="2026-10-01T12:00:00+00:00">\(digest)</\(tag)>
                </hash>
              </hashes>
            </hashlist>
            """
        return try #require(try MHLReader.read(Data(xml.utf8)).entries.first)
    }

    /// `EngineHarness.standardFiles` as the reference ascmhl hashes it,
    /// computed once outside this suite. The script transcribes ascmhl 1.2's
    /// directory-hash code (`hasher.DirectoryHashContext` over
    /// `traverse.post_order_lexicographic`, github.com/ascmitc/mhl), uses an
    /// XXH64 written from the xxHash spec and checked against its published
    /// vectors, and ran over the fixture written to disk beside ignored
    /// evidence. Nothing here comes from `DirectoryHashes` or the app's
    /// hashers, so a drift in either fails these pins.
    private static let referenceFileDigests: [String: String] = [
        "DCIM/100MEDIA/a.bin": "1d094e6fb15c2c18",
        "DCIM/100MEDIA/b.bin": "f15d57e5b3249186",
        "MISC/c.txt": "11091c063bdb0a69",
    ]

    /// Root (".") and directory content/structure hashes of the same run.
    private static let referenceDirectoryHashes: [String: (content: String, structure: String)] = [
        ".": ("b0a0957b12766d28", "fcced3d19078347c"),
        "DCIM": ("9b3dfee31614be40", "9a667082bd3bb87a"),
        "DCIM/100MEDIA": ("ba07791a46eb4fb3", "61448e1698871cdb"),
        "MISC": ("9dac7ce8354f7573", "dd869591381ad6a8"),
    ]

    /// Expects `document`'s root and directory hashes to be exactly the
    /// reference ones for `EngineHarness.standardFiles`.
    private static func expectReferenceDirectoryHashes(_ document: MHLDocument) throws {
        let root = try #require(referenceDirectoryHashes["."])
        #expect(document.rootContentDigests[.xxh64] == root.content)
        #expect(document.rootStructureDigests[.xxh64] == root.structure)
        #expect(Set(document.directories.map(\.relativePath)) == Set(referenceDirectoryHashes.keys).subtracting(["."]))
        for directory in document.directories {
            let expected = referenceDirectoryHashes[directory.relativePath]
            #expect(directory.contentDigests[.xxh64] == expected?.content, "\(directory.relativePath)")
            #expect(directory.structureDigests[.xxh64] == expected?.structure, "\(directory.relativePath)")
        }
    }

    /// What ascmhl hashes in `folder` as it is on disk under the `<ignore>`
    /// patterns `xml` declares: each remaining regular file, hashed from its
    /// bytes.
    ///
    /// ascmhl also hashes every remaining directory, an empty one included,
    /// into its parent; a file list cannot show those. So the folder must hold
    /// no remaining directory without a remaining file beneath it, or this
    /// oracle could agree with a root hash ascmhl would not compute.
    private static func mediaOnDisk(of folder: URL, ignoring xml: String) throws -> [String: String] {
        let scan = try scanOnDisk(folder, ignoring: xml)
        try #require(
            scan.directoriesWithoutMedia.isEmpty,
            "directories ascmhl would hash but a file list cannot show: \(scan.directoriesWithoutMedia.sorted())"
        )
        return scan.media
    }

    /// `folder` under `xml`'s `<ignore>` patterns: each remaining regular file
    /// with the digest of its bytes, and each remaining directory with no
    /// remaining file beneath it. Every pattern doppelganger writes is a bare
    /// name, matched at any depth, with an optional trailing "/" (directories)
    /// or "*" (a name prefix).
    private static func scanOnDisk(
        _ folder: URL,
        ignoring xml: String
    ) throws -> (media: [String: String], directoriesWithoutMedia: Set<String>) {
        let patterns = xml.matches(of: #/<pattern>([^<]+)</pattern>/#).map { match in
            let pattern = String(match.1)
            return pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
        }
        func ignored(_ path: String) -> Bool {
            path.split(separator: "/").contains { name in
                patterns.contains { $0.hasSuffix("*") ? name.hasPrefix($0.dropLast()) : name == $0 }
            }
        }
        let resolved = folder.resolvingSymlinksInPath()
        let enumerator = try #require(FileManager.default.enumerator(
            at: resolved,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ))
        var media: [String: String] = [:]
        var directories: Set<String> = []
        for case let url as URL in enumerator {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))
            guard !ignored(path) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true {
                directories.insert(path)
            } else if values.isRegularFile == true {
                media[path] = xxh64([UInt8](try Data(contentsOf: url)))
            }
        }
        var holdingMedia: Set<String> = []
        for path in media.keys {
            var directory = (path as NSString).deletingLastPathComponent
            while !directory.isEmpty, holdingMedia.insert(directory).inserted {
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return (media, directories.subtracting(holdingMedia))
    }

    /// A Standard offload whose a.bin write is corrupted: the parent fails
    /// that pair on its read-back checksum, verifies the other two, and so
    /// writes no ASC MHL generation.
    private static func makeFailedParent(
        in fixtures: FixtureBuilder
    ) async throws -> (destination: URL, source: URL, failed: TransferReport) {
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "destination")
        let faulty = FailpointFileSystem(base: RealFileSystem())
        faulty.corruptFirstByteOnWrite(pathSuffix: "destination/DCIM/100MEDIA/a.bin")

        let failed = try await EngineHarness.run(
            fileSystem: faulty,
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("failed-spool")
        ).report
        #expect(failed.status == .failed)
        let corrupted = failed.outcome("DCIM/100MEDIA/a.bin", at: destination)
        #expect(
            { if case .failed(.checksumMismatch) = corrupted { true } else { false } }(),
            "\(String(describing: corrupted))"
        )
        #expect(failed.outcome("DCIM/100MEDIA/b.bin", at: destination) == .verified)
        #expect(failed.outcome("MISC/c.txt", at: destination) == .verified)
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(MHLWriter.directoryName).path
        ))
        return (destination, source, failed)
    }

    /// The fine-grained repair of exactly the failed pair, as
    /// `AppModel.retryFailures` requests it (same output folder).
    private static func repair(
        _ failed: TransferReport,
        at destination: URL,
        from source: URL,
        in fixtures: FixtureBuilder
    ) async throws -> TransferReport {
        try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("retry-spool"),
            retryManifest: try EngineHarness.decodeManifest(at: destination, shortID: failed.shortID),
            includedRelativePaths: ["DCIM/100MEDIA/a.bin"]
        ).report
    }

    /// The failed parent, then its verified repair.
    private static func makeRepairedDestination(
        in fixtures: FixtureBuilder
    ) async throws -> (destination: URL, failed: TransferReport) {
        let (destination, source, failed) = try await makeFailedParent(in: fixtures)
        let repaired = try await repair(failed, at: destination, from: source, in: fixtures)
        #expect(repaired.status == .verified, "\(repaired.issues)")
        #expect(repaired.items.map(\.item.relativePath) == ["DCIM/100MEDIA/a.bin"])
        return (destination, failed)
    }

    private static let destination = URL(fileURLWithPath: "/Volumes/Shuttle/day01")

    /// A verified single-destination report for the pure generation tests.
    private static func report(_ files: [(path: String, digest: String)]) -> TransferReport {
        TransferReport(
            id: ReportFixtures.transferID,
            status: .verified,
            algorithm: .xxh64,
            sourceRoot: ReportFixtures.source,
            destinations: [destination],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: files.map {
                ItemResult(
                    item: SourceItem(relativePath: $0.path, size: 10),
                    sourceDigest: $0.digest,
                    outcomes: [destination: .verified]
                )
            },
            manifestLocations: [destination]
        )
    }

    private static func generation(
        _ report: TransferReport,
        _ context: MHLWriter.FolderContext
    ) throws -> (xml: String, document: MHLDocument) {
        let generation = try #require(try MHLWriter.generation(
            for: report,
            destination: destination,
            sequence: 2,
            context: context,
            hostName: "test"
        ))
        return (String(decoding: generation.data, as: UTF8.self), try MHLReader.read(generation.data))
    }

    // MARK: - Actions

    /// Port of Repro_G09_mhl.repro_firstGenerationRecordsOriginalHashes,
    /// tightened: a full offload into a fresh folder records every file as
    /// "original" and keeps an honest root hash.
    @Test func firstGenerationRecordsEveryHashAsOriginal() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool")
        )
        #expect(run.report.status == .verified)

        let generations = try Self.generations(in: destination)
        #expect(generations.count == 1)
        let first = try #require(generations.first)
        #expect(Self.actions(in: first.xml) == Self.allOriginal(EngineHarness.standardFiles))
        #expect(!first.xml.contains(#"action="verified""#))
        try Self.expectReferenceDirectoryHashes(first.document)
    }

    /// The pins themselves: the fixture's bytes hash to the reference file
    /// digests, and `DirectoryHashes` aggregates them exactly as ascmhl does.
    @Test func directoryHashesMatchTheReferenceImplementation() throws {
        let items = EngineHarness.standardFiles.map {
            ItemResult(
                item: SourceItem(relativePath: $0.path, size: Int64($0.size)),
                sourceDigest: Self.xxh64($0.bytes),
                outcomes: [:]
            )
        }
        #expect(Dictionary(uniqueKeysWithValues: items.map { ($0.item.relativePath, $0.sourceDigest ?? "") })
            == Self.referenceFileDigests)

        let calculated = DirectoryHashes.calculate(items: items, algorithm: .xxh64)
        #expect(Set(calculated.map(\.path)) == Set(Self.referenceDirectoryHashes.keys))
        for record in calculated {
            let expected = Self.referenceDirectoryHashes[record.path]
            #expect(record.content == expected?.content, "\(record.path)")
            #expect(record.structure == expected?.structure, "\(record.path)")
        }
    }

    /// ascmhl's rule against the folder's history: "original" until an
    /// original exists, then "verified" on a match; anything contradictory
    /// refuses the generation.
    @Test func actionsFollowTheFolderHistory() throws {
        let path = "A001.MP4"
        let digest = "0123456789abcdef"
        let other = "1111111111111111"
        func action(after history: [MHLDocument.Entry]) throws -> String? {
            let context = MHLWriter.FolderContext(history: history, folderMedia: [path])
            return Self.actions(in: try Self.generation(Self.report([(path, digest)]), context).xml)[path]
        }
        func entry(_ digest: String, _ action: String, tag: String = "xxh64") throws -> MHLDocument.Entry {
            try Self.historyEntry(path, tag: tag, digest: digest, action: action)
        }

        #expect(try action(after: []) == "original")
        #expect(try action(after: [entry(digest, "original")]) == "verified")
        // Histories written by older builds hold only "verified".
        #expect(try action(after: [entry(digest, "verified")]) == "original")
        // A recorded failure is not a baseline, and neither is a hash under an
        // action ASC MHL does not define.
        #expect(try action(after: [entry(digest, "original"), entry(other, "failed")]) == "verified")
        #expect(try action(after: [entry(digest, "original"), entry(other, "rehashed")]) == "verified")
        #expect(try action(after: [entry(digest, "Rehashed")]) == "original")
        #expect(throws: MHLHistoryError.conflictingHistory(path: path)) {
            try action(after: [entry(other, "original")])
        }
        #expect(throws: MHLHistoryError.conflictingHistory(path: path)) {
            try action(after: [entry(digest, "original"), entry(other, "verified")])
        }
        // A format added later ("new") is a hash of the bytes like any other.
        #expect(throws: MHLHistoryError.conflictingHistory(path: path)) {
            try action(after: [entry(digest, "original"), entry(other, " NEW ")])
        }
        // An original this run cannot compare in its own format.
        #expect(throws: MHLHistoryError.conflictingHistory(path: path)) {
            try action(after: [entry("900150983cd24fb0d6963f7d28e17f72", "original", tag: "md5")])
        }
    }

    /// A refused generation writes nothing: the chain, its archive and the
    /// earlier generation stay exactly as they were.
    @Test func conflictingHistoryLeavesTheChainUntouched() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "history")
        let fileSystem = RealFileSystem()
        func report(digest: String, finishedAt: Date) -> TransferReport {
            TransferReport(
                id: UUID(),
                status: .verified,
                algorithm: .xxh64,
                sourceRoot: ReportFixtures.source,
                destinations: [destination],
                startedAt: ReportFixtures.started,
                finishedAt: finishedAt,
                items: [ItemResult(
                    item: SourceItem(relativePath: "A001.MP4", size: 10),
                    sourceDigest: digest,
                    outcomes: [destination: .verified]
                )],
                manifestLocations: [destination]
            )
        }
        _ = try #require(try MHLHistoryStore.append(
            report: report(digest: "0123456789abcdef", finishedAt: ReportFixtures.finished),
            destination: destination,
            fileSystem: fileSystem
        ))
        let directory = destination.appendingPathComponent(MHLWriter.directoryName)
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        let chainBefore = try Data(contentsOf: chainURL)
        let contentsBefore = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        #expect(throws: MHLHistoryError.conflictingHistory(path: "A001.MP4")) {
            try MHLHistoryStore.append(
                report: report(digest: "1111111111111111", finishedAt: ReportFixtures.finished + 60),
                destination: destination,
                fileSystem: fileSystem
            )
        }

        #expect(try Data(contentsOf: chainURL) == chainBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == contentsBefore)
        #expect(contentsBefore.count == 2)
        #expect(try MHLReader.validateChain(at: directory).entries.map(\.sequence) == [1])
    }

    /// End to end: an offload into a folder whose history already records a
    /// different hash for one of its paths is a failed transfer with readable
    /// evidence, never a contradicting generation. Every copy stays in place.
    @Test func contradictoryHistoryFailsTheTransferAndKeepsTheChain() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")
        let stale = TransferReport(
            id: UUID(),
            status: .verified,
            algorithm: .xxh64,
            sourceRoot: ReportFixtures.source,
            destinations: [destination],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: [ItemResult(
                item: SourceItem(relativePath: "DCIM/100MEDIA/a.bin", size: 200_000),
                sourceDigest: "1111111111111111",
                outcomes: [destination: .verified]
            )],
            manifestLocations: [destination]
        )
        _ = try #require(try MHLHistoryStore.append(report: stale, destination: destination, fileSystem: RealFileSystem()))
        let chainURL = destination
            .appendingPathComponent(MHLWriter.directoryName)
            .appendingPathComponent(MHLWriter.chainFileName)
        let chainBefore = try Data(contentsOf: chainURL)

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool")
        )

        #expect(run.report.status == .failed)
        #expect(run.report.issues.contains {
            $0.contains("ASC MHL history already records") && $0.contains("DCIM/100MEDIA/a.bin")
        }, "\(run.report.issues)")
        #expect(try Data(contentsOf: chainURL) == chainBefore)
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes, "\(spec.path)")
        }
    }

    // MARK: - Root and directory hashes

    @Test func rootAndDirectoryHashesNeedTheWholeFolder() throws {
        let report = Self.report([
            ("DCIM/100MEDIA/A001.MP4", "0123456789abcdef"),
            ("MISC/c.txt", "fedcba9876543210"),
        ])
        let listed: Set<String> = ["DCIM/100MEDIA/A001.MP4", "MISC/c.txt"]

        let whole = try Self.generation(report, MHLWriter.FolderContext(folderMedia: listed)).document
        #expect(whole.rootContentDigests[.xxh64] != nil)
        #expect(whole.rootStructureDigests[.xxh64] != nil)
        #expect(Set(whole.directories.map(\.relativePath)) == ["DCIM", "DCIM/100MEDIA", "MISC"])

        // An unlisted clip on disk leaves its directories, and the root,
        // undescribed; MISC is still fully listed.
        let partial = try Self.generation(
            report,
            MHLWriter.FolderContext(folderMedia: listed.union(["DCIM/100MEDIA/A003.MP4"]))
        ).document
        #expect(partial.rootContentDigests.isEmpty)
        #expect(partial.rootStructureDigests.isEmpty)
        #expect(partial.directories.map(\.relativePath) == ["MISC"])

        // A folder that could not be listed proves nothing about any directory.
        let unlisted = try Self.generation(report, MHLWriter.FolderContext(folderMedia: nil))
        #expect(unlisted.document.rootContentDigests.isEmpty)
        #expect(unlisted.document.directories.isEmpty)
        #expect(!unlisted.xml.contains("<roothash>"))
        #expect(Self.actions(in: unlisted.xml).count == 2)
    }

    /// The ignore list and the coverage check agree: the retry quarantine
    /// tree, staging files, doppelganger's own evidence and OS metadata are
    /// declared ignored, so they never cost the folder its root hash.
    @Test func ignoredEvidenceAndMetadataDoNotBlockTheRootHash() throws {
        let report = Self.report([("DCIM/100MEDIA/A001.MP4", "0123456789abcdef")])
        let folderMedia: Set<String> = [
            "DCIM/100MEDIA/A001.MP4",
            ".doppelganger-failed/abcd1234/DCIM/100MEDIA/A001.MP4",
            "DCIM/100MEDIA/._A001.MP4",
            ".fseventsd/0000000000000001",
            ".doppelganger-partial-abcd1234-A002.MP4",
            "doppelganger-manifest-abcd1234.json",
            "DCIM/.DS_Store",
            "ascmhl/0001_day01.mhl",
        ]

        let generation = try Self.generation(report, MHLWriter.FolderContext(folderMedia: folderMedia))

        #expect(generation.document.rootContentDigests[.xxh64] != nil)
        #expect(Set(generation.document.directories.map(\.relativePath)) == ["DCIM", "DCIM/100MEDIA"])
        for pattern in [".doppelganger-failed", "._*", ".fseventsd", ".doppelganger-partial-*", "doppelganger-*", "ascmhl"] {
            #expect(generation.xml.contains("<pattern>\(pattern)</pattern>"), "\(pattern)")
        }
    }

    /// A listed file whose name other tools are told to ignore cannot back a
    /// directory hash they would recompute without it.
    @Test func aListedFileOtherToolsIgnoreSuppressesItsDirectories() throws {
        let report = Self.report([
            ("clips/doppelganger-take.mov", "0123456789abcdef"),
            ("other/A001.MP4", "fedcba9876543210"),
        ])
        let folderMedia: Set<String> = ["clips/doppelganger-take.mov", "other/A001.MP4"]

        let document = try Self.generation(report, MHLWriter.FolderContext(folderMedia: folderMedia)).document

        #expect(document.rootContentDigests.isEmpty)
        #expect(document.directories.map(\.relativePath) == ["other"])
        #expect(document.entries.count == 2)
    }

    /// Port of Repro_G09_mhl.repro_directLayoutLatestRootHashIsHonest,
    /// tightened: two offloads straight into one base share its chain; each
    /// generation lists only its own files as "original", and only the one
    /// that described the whole base claims a root hash.
    @Test func directLayoutGenerationsDescribeOnlyWhatTheyCover() async throws {
        let fixtures = try FixtureBuilder()
        let cardA = try fixtures.makeCard(
            named: "cardA",
            files: [.init("A001/A001C001.mov", size: 30_000, seed: 61)]
        )
        let cardB = try fixtures.makeCard(
            named: "cardB",
            files: [.init("B001/B001C001.mov", size: 30_000, seed: 62)]
        )
        let base = try fixtures.makeDestination(named: "shuttle")

        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardA,
            destinations: [base],
            spool: fixtures.root.appendingPathComponent("spool-a")
        )
        #expect(first.report.status == .verified)
        let second = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: cardB,
            destinations: [base],
            spool: fixtures.root.appendingPathComponent("spool-b")
        )
        #expect(second.report.status == .verified)

        let generations = try Self.generations(in: base)
        try #require(generations.count == 2)
        #expect(Self.actions(in: generations[0].xml) == ["A001/A001C001.mov": "original"])
        #expect(generations[0].document.rootContentDigests[.xxh64] != nil)
        #expect(Self.actions(in: generations[1].xml) == ["B001/B001C001.mov": "original"])
        #expect(generations[1].document.rootContentDigests.isEmpty)
        #expect(generations[1].document.rootStructureDigests.isEmpty)
        #expect(generations[1].document.directories.map(\.relativePath) == ["B001"])
        // ascmhl looks up each file's original across the whole chain.
        let originals = generations.reduce(into: Set<String>()) { result, generation in
            result.formUnion(Self.actions(in: generation.xml).filter { $0.value == "original" }.keys)
        }
        #expect(originals == ["A001/A001C001.mov", "B001/B001C001.mov"])
    }

    // MARK: - Repair

    /// Port of Repro_G09_mhl.repro_repairHistoryCoversWholeFolderAndRootHashIsHonest,
    /// end to end. The failed parent writes no generation, so the repair's is
    /// the folder's whole history: the repaired pair and both pairs the parent
    /// verified, each a first sighting ("original", never "verified"), under
    /// the root and directory hashes ascmhl computes over the folder on disk.
    /// The quarantined bytes are declared ignored, so they cost nothing.
    @Test func repairGenerationDescribesTheWholeRepairedFolder() async throws {
        let fixtures = try FixtureBuilder()
        let (destination, failed) = try await Self.makeRepairedDestination(in: fixtures)
        let parent = try EngineHarness.decodeManifest(at: destination, shortID: failed.shortID)
        let quarantined = destination
            .appendingPathComponent(".doppelganger-failed")
            .appendingPathComponent(failed.shortID)
            .appendingPathComponent("DCIM/100MEDIA/a.bin")
        #expect(FileManager.default.fileExists(atPath: quarantined.path))

        let generations = try Self.generations(in: destination)
        try #require(generations.count == 1)
        let history = generations[0]

        // Every file, each as a first sighting with the digest of its bytes.
        #expect(Self.actions(in: history.xml) == Self.allOriginal(EngineHarness.standardFiles))
        #expect(!history.xml.contains(#"action="verified""#))
        #expect(history.document.entries.count == EngineHarness.standardFiles.count)
        for spec in EngineHarness.standardFiles {
            let record = history.document.entries.first { $0.relativePath == spec.path }
            #expect(record?.digests[.xxh64] == Self.xxh64(spec.bytes), "\(spec.path)")
            #expect(record?.size == Int64(spec.size), "\(spec.path)")
        }
        // Carried hashes keep the parent's provenance; the repaired one is
        // dated by the repair's generation itself.
        let dates = Self.hashDates(in: history.xml)
        #expect(dates["DCIM/100MEDIA/b.bin"] == parent.finishedAt)
        #expect(dates["MISC/c.txt"] == parent.finishedAt)
        #expect(dates["DCIM/100MEDIA/a.bin"] == history.document.creationDate)
        #expect(dates["DCIM/100MEDIA/a.bin"] != parent.finishedAt)

        // What is on disk, minus what this generation tells ascmhl to ignore,
        // is exactly the reference fixture, so the root and every directory
        // hash must be the ones the reference ascmhl computes over it.
        #expect(history.xml.contains("<pattern>.doppelganger-failed</pattern>"))
        #expect(try Self.mediaOnDisk(of: destination, ignoring: history.xml) == Self.referenceFileDigests)
        try Self.expectReferenceDirectoryHashes(history.document)
    }

    /// A copy the parent verified that is gone by the time of the repair: no
    /// history can describe the folder, so the repair fails with readable
    /// evidence and writes no generation. No media is touched: the repaired
    /// copy, the parent's other copy and its quarantined bytes all stay.
    @Test func repairFailsWhenAParentVerifiedCopyIsGone() async throws {
        let fixtures = try FixtureBuilder()
        let (destination, source, failed) = try await Self.makeFailedParent(in: fixtures)
        // Synthetic fixture only: a parent-verified copy removed after the parent.
        try FileManager.default.removeItem(at: destination.appendingPathComponent("MISC/c.txt"))

        let repair = try await Self.repair(failed, at: destination, from: source, in: fixtures)

        #expect(repair.status == .failed)
        #expect(repair.outcome("DCIM/100MEDIA/a.bin", at: destination) == .verified)
        #expect(repair.issues.contains(
            "Could not write a complete ASC MHL generation: "
                + MHLHistoryError.carriedCopyChanged(path: "MISC/c.txt").description
        ), "\(repair.issues)")
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(MHLWriter.directoryName).path
        ))
        let record = try EngineHarness.decodeManifest(at: destination, shortID: repair.shortID)
        #expect(record.status == TransferStatus.failed.rawValue)
        for path in ["DCIM/100MEDIA/a.bin", "DCIM/100MEDIA/b.bin"] {
            #expect(
                try fixtures.bytes(at: destination.appendingPathComponent(path))
                    == fixtures.bytes(at: source.appendingPathComponent(path)),
                "\(path)"
            )
        }
        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent(".doppelganger-failed")
            .appendingPathComponent(failed.shortID)
            .appendingPathComponent("DCIM/100MEDIA/a.bin").path))
    }

    /// This attempt never re-read a carried copy, so a carried hash may supply
    /// a path's first original but never claim "verified": where the history
    /// already holds an original, the path is left to it (and the root hash
    /// goes with it). A carried hash that contradicts the history refuses the
    /// generation.
    @Test func carriedHashesOnlySupplyAFirstOriginal() throws {
        let clip = "DCIM/100MEDIA/A001.MP4"
        let carriedPath = "MISC/c.txt"
        let carriedDigest = "fedcba9876543210"
        let report = Self.report([(clip, "0123456789abcdef")])
        let carried = MHLWriter.HashRecord(
            relativePath: carriedPath,
            size: 10,
            modifiedAt: nil,
            digest: carriedDigest,
            hashDate: "2026-10-01T12:00:00.000Z"
        )
        let folderMedia: Set<String> = [clip, carriedPath]

        let first = try Self.generation(report, MHLWriter.FolderContext(carried: [carried], folderMedia: folderMedia))
        #expect(Self.actions(in: first.xml) == [clip: "original", carriedPath: "original"])
        #expect(Self.hashDates(in: first.xml)[carriedPath] == "2026-10-01T12:00:00.000Z")
        #expect(first.document.rootContentDigests[.xxh64] != nil)

        let described = try Self.generation(report, MHLWriter.FolderContext(
            history: [try Self.historyEntry(carriedPath, digest: carriedDigest, action: "original")],
            carried: [carried],
            folderMedia: folderMedia
        ))
        #expect(Self.actions(in: described.xml) == [clip: "original"])
        #expect(described.document.rootContentDigests.isEmpty)
        #expect(Set(described.document.directories.map(\.relativePath)) == ["DCIM", "DCIM/100MEDIA"])

        // An older build's history holds only "verified": the carried hash
        // supplies the original ascmhl looks for.
        let unoriginal = try Self.generation(report, MHLWriter.FolderContext(
            history: [try Self.historyEntry(carriedPath, digest: carriedDigest, action: "verified")],
            carried: [carried],
            folderMedia: folderMedia
        ))
        #expect(Self.actions(in: unoriginal.xml) == [clip: "original", carriedPath: "original"])

        #expect(throws: MHLHistoryError.conflictingHistory(path: carriedPath)) {
            try Self.generation(report, MHLWriter.FolderContext(
                history: [try Self.historyEntry(carriedPath, digest: "1111111111111111", action: "original")],
                carried: [carried],
                folderMedia: folderMedia
            ))
        }
    }

    /// A repair of a failed repair carries only its immediate parent's
    /// verified pairs. The grandparent's file stays unlisted, so the history
    /// is honest but partial: no root hash, and no hash for that directory.
    @Test func chainedRepairWritesAnHonestPartialHistory() throws {
        let fixtures = try FixtureBuilder()
        let specs = EngineHarness.standardFiles
        let destination = try fixtures.makeCard(named: "destination", files: specs)
        func attempt(_ outcomes: [(FixtureBuilder.FileSpec, ItemDestinationOutcome)], finishedAt: Date) -> TransferReport {
            let failed = outcomes.contains { if case .failed = $0.1 { true } else { false } }
            return TransferReport(
                id: UUID(),
                status: failed ? .failed : .verified,
                algorithm: .xxh64,
                sourceRoot: ReportFixtures.source,
                destinations: [destination],
                startedAt: ReportFixtures.started,
                finishedAt: finishedAt,
                items: outcomes.map { spec, outcome in
                    ItemResult(
                        item: SourceItem(relativePath: spec.path, size: Int64(spec.size)),
                        sourceDigest: Self.xxh64(spec.bytes),
                        outcomes: [destination: outcome]
                    )
                },
                manifestLocations: [destination]
            )
        }
        let corrupt = ItemDestinationOutcome.failed(.checksumMismatch(expected: "0", actual: "1"))
        // Grandparent: a and b failed, c verified. First repair: a verified, b
        // failed again. Second repair: b verified.
        let firstRepair = attempt([(specs[0], .verified), (specs[1], corrupt)], finishedAt: ReportFixtures.finished)
        let secondRepair = attempt([(specs[1], .verified)], finishedAt: ReportFixtures.finished + 60)

        _ = try #require(try MHLHistoryStore.append(
            report: secondRepair,
            destination: destination,
            carryingVerifiedPairsFrom: TransferManifest(report: firstRepair),
            fileSystem: RealFileSystem()
        ))

        let generations = try Self.generations(in: destination)
        #expect(generations.count == 1)
        let history = try #require(generations.first)
        #expect(Self.actions(in: history.xml) == Self.allOriginal([specs[0], specs[1]]))
        #expect(history.document.rootContentDigests.isEmpty)
        #expect(Set(history.document.directories.map(\.relativePath)) == ["DCIM", "DCIM/100MEDIA"])
    }

    // MARK: - The on-disk oracle

    /// The oracle sees the directories ascmhl hashes, not only the files: an
    /// empty directory is reported (it would change its parent's structure
    /// hash), while one under an ignored tree costs nothing.
    @Test func onDiskOracleReportsDirectoriesWithoutMedia() throws {
        let fixtures = try FixtureBuilder()
        let folder = try fixtures.makeCard(named: "folder", files: EngineHarness.standardFiles)
        let ignore = "<pattern>.doppelganger-failed</pattern>"
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(".doppelganger-failed/abcd1234/EMPTY"),
            withIntermediateDirectories: true
        )
        let clean = try Self.scanOnDisk(folder, ignoring: ignore)
        #expect(clean.media == Self.referenceFileDigests)
        #expect(clean.directoriesWithoutMedia.isEmpty)

        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("DCIM/EMPTY/DEEPER"),
            withIntermediateDirectories: true
        )
        let withEmpty = try Self.scanOnDisk(folder, ignoring: ignore)
        #expect(withEmpty.media == Self.referenceFileDigests)
        #expect(withEmpty.directoriesWithoutMedia == ["DCIM/EMPTY", "DCIM/EMPTY/DEEPER"])
    }

    // MARK: - Digests read back from a manifest

    /// `digest` with its first "f" (0x66) turned into "&" (0x26), a single
    /// bit flip: the manifest holding it is still valid JSON, but the digest
    /// is neither hex nor safe to write into XML.
    private static func bitFlipped(_ digest: String) throws -> String {
        let flipped = digest.replacing("f", with: "&", maxReplacements: 1)
        try #require(flipped != digest)
        return flipped
    }

    /// A synthetic attempt over `outcomes` at its one destination.
    private static func syntheticAttempt(
        _ outcomes: [(FixtureBuilder.FileSpec, ItemDestinationOutcome)],
        at destination: URL,
        status: TransferStatus,
        finishedAt: Date = ReportFixtures.finished
    ) -> TransferReport {
        TransferReport(
            id: UUID(),
            status: status,
            algorithm: .xxh64,
            sourceRoot: ReportFixtures.source,
            destinations: [destination],
            startedAt: ReportFixtures.started,
            finishedAt: finishedAt,
            items: outcomes.map { spec, outcome in
                ItemResult(
                    item: SourceItem(relativePath: spec.path, size: Int64(spec.size)),
                    sourceDigest: xxh64(spec.bytes),
                    outcomes: [destination: outcome]
                )
            },
            manifestLocations: [destination]
        )
    }

    @Test func onlyCanonicalDigestsAreWellFormed() {
        #expect(MHLWriter.isWellFormedDigest("0123456789abcdef", algorithm: .xxh64))
        #expect(MHLWriter.isWellFormedDigest("0123456789abcdef", algorithm: .xxh3))
        #expect(MHLWriter.isWellFormedDigest("900150983cd24fb0d6963f7d28e17f72", algorithm: .md5))
        for digest in [
            "&123456789abcdef", "0123456789abcde", "0123456789abcdef0", "0123456789abcdeg",
            "0123456789ABCDEF", "0123456789abcd\u{00E9}", "", " 123456789abcdef",
        ] {
            #expect(!MHLWriter.isWellFormedDigest(digest, algorithm: .xxh64), "\(digest)")
        }
        #expect(!MHLWriter.isWellFormedDigest("0123456789abcdef", algorithm: .md5))
        #expect(!MHLWriter.isWellFormedDigest("900150983cd24fb0d6963f7d28e17f72", algorithm: .xxh3))
    }

    /// A parent manifest damaged on disk. A carried hash that
    /// is not a digest in the transfer's format refuses the repair's history,
    /// rather than writing a malformed or schema-invalid generation that every
    /// later append to the folder would then fail on. A case-only difference is
    /// the same digest and is carried in canonical form.
    @Test func malformedCarriedDigestRefusesTheRepairHistory() throws {
        let specs = EngineHarness.standardFiles
        let carriedPath = specs[1].path
        let digest = Self.xxh64(specs[1].bytes)
        let corrupt = ItemDestinationOutcome.failed(.checksumMismatch(expected: "0", actual: "1"))
        func attempts(at destination: URL, carrying carriedDigest: String) throws
            -> (repair: TransferReport, parent: TransferManifest) {
            var parent = TransferManifest(report: Self.syntheticAttempt(
                [(specs[0], corrupt), (specs[1], .verified), (specs[2], .verified)],
                at: destination,
                status: .failed
            ))
            let index = try #require(parent.items.firstIndex { $0.relativePath == carriedPath })
            parent.items[index].digest = carriedDigest
            let repair = Self.syntheticAttempt(
                [(specs[0], .verified)],
                at: destination,
                status: .verified,
                finishedAt: ReportFixtures.finished + 60
            )
            return (repair, parent)
        }

        for damaged in [try Self.bitFlipped(digest), String(digest.dropLast()), String(digest.dropLast()) + "g"] {
            let fixtures = try FixtureBuilder()
            // Synthetic fixture only: the folder the parent and repair verified.
            let destination = try fixtures.makeCard(named: "destination", files: specs)
            let (repair, parent) = try attempts(at: destination, carrying: damaged)

            #expect(throws: MHLHistoryError.malformedDigest(path: carriedPath), "\(damaged)") {
                try MHLHistoryStore.append(
                    report: repair,
                    destination: destination,
                    carryingVerifiedPairsFrom: parent,
                    fileSystem: RealFileSystem()
                )
            }
            #expect(!FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(MHLWriter.directoryName).path
            ), "\(damaged)")
        }

        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeCard(named: "destination", files: specs)
        let (repair, parent) = try attempts(at: destination, carrying: digest.uppercased())
        _ = try #require(try MHLHistoryStore.append(
            report: repair,
            destination: destination,
            carryingVerifiedPairsFrom: parent,
            fileSystem: RealFileSystem()
        ))
        let history = try #require(try Self.generations(in: destination).first)
        #expect(history.xml.contains(">\(digest)</xxh64>"))
        #expect(!history.xml.contains(digest.uppercased()))
        // The folder holds exactly the reference fixture, all of it listed.
        try Self.expectReferenceDirectoryHashes(history.document)
    }

    /// End to end, as `AppModel.retryFailures` reads the parent: its manifest
    /// on the destination takes a one-bit flip in a verified pair's digest and
    /// still decodes. The repair fails with readable evidence and leaves the
    /// folder with no history it could never append to again. No media is
    /// touched.
    @Test func damagedParentManifestFailsTheRepairAndWritesNoHistory() async throws {
        let fixtures = try FixtureBuilder()
        let (destination, source, failed) = try await Self.makeFailedParent(in: fixtures)
        let carriedPath = "DCIM/100MEDIA/b.bin"
        let manifestURL = destination.appendingPathComponent(ManifestWriter.manifestFileName(shortID: failed.shortID))
        let digest = try #require(
            try EngineHarness.decodeManifest(at: destination, shortID: failed.shortID)
                .items.first { $0.relativePath == carriedPath }?.digest
        )
        // Synthetic fixture only: damage the parent's own record of the test run.
        let json = try String(contentsOf: manifestURL, encoding: .utf8)
        try #require(json.components(separatedBy: digest).count == 2)
        let flipped = try Self.bitFlipped(digest)
        try json.replacingOccurrences(of: digest, with: flipped).write(to: manifestURL, atomically: true, encoding: .utf8)
        let parent = try EngineHarness.decodeManifest(at: destination, shortID: failed.shortID)

        let repair = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("retry-spool"),
            retryManifest: parent,
            includedRelativePaths: ["DCIM/100MEDIA/a.bin"]
        ).report

        #expect(repair.status == .failed)
        #expect(repair.outcome("DCIM/100MEDIA/a.bin", at: destination) == .verified)
        #expect(repair.issues.contains(
            "Could not write a complete ASC MHL generation: "
                + MHLHistoryError.malformedDigest(path: carriedPath).description
        ), "\(repair.issues)")
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(MHLWriter.directoryName).path
        ))
        for spec in EngineHarness.standardFiles {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes, "\(spec.path)")
        }
        #expect(FileManager.default.fileExists(atPath: destination
            .appendingPathComponent(".doppelganger-failed")
            .appendingPathComponent(failed.shortID)
            .appendingPathComponent("DCIM/100MEDIA/a.bin").path))
    }

    /// The same damage reaches a resume: a pair restored from the paused
    /// attempt's manifest keeps that manifest's digest without re-reading the
    /// copy. The resume fails rather than writing a malformed generation, and
    /// every restored copy stays in place.
    @Test func damagedResumeManifestFailsTheResumeAndWritesNoHistory() async throws {
        let fixtures = try FixtureBuilder()
        let specs = EngineHarness.standardFiles
        let source = try fixtures.makeCard(files: specs)
        // Synthetic fixture only: the copies a paused attempt verified.
        let destination = try fixtures.makeCard(named: "destination", files: specs)
        var paused = TransferManifest(report: Self.syntheticAttempt(
            specs.map { ($0, .verified) },
            at: destination,
            status: .paused
        ))
        let restoredPath = specs[0].path
        let index = try #require(paused.items.firstIndex { $0.relativePath == restoredPath })
        paused.items[index].digest = try Self.bitFlipped(Self.xxh64(specs[0].bytes))
        let parent = try ManifestWriter.decode(ManifestWriter.jsonData(for: paused))

        let resumed = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("resume-spool"),
            resumeManifest: parent
        ).report

        #expect(resumed.status == .failed)
        #expect(resumed.outcome(restoredPath, at: destination) == .verified)
        #expect(resumed.issues.contains(
            "Could not write a complete ASC MHL generation: "
                + MHLHistoryError.malformedDigest(path: restoredPath).description
        ), "\(resumed.issues)")
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(MHLWriter.directoryName).path
        ))
        for spec in specs {
            #expect(try fixtures.bytes(at: destination.appendingPathComponent(spec.path)) == spec.bytes, "\(spec.path)")
        }
    }
}
