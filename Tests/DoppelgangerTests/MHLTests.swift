import Foundation
import Testing
@testable import Doppelganger

struct MHLTests {
    @Test func verifiedReportProducesASCMHLV2WithRootAndDirectoryHashes() throws {
        let xml = try #require(
            MHLWriter.xml(for: ReportFixtures.verifiedReport(), destination: ReportFixtures.destinationA)
        )
        #expect(xml.contains(#"<hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">"#))
        #expect(xml.contains("<process>transfer</process>"))
        #expect(xml.contains("<roothash>"))
        #expect(xml.contains("<directoryhash>"))
        #expect(xml.contains(#"<xxh64 action="verified" hashdate="2025-08-09T00:44:02.500Z">0123456789abcdef</xxh64>"#))

        let document = try MHLReader.read(Data(xml.utf8))
        #expect(document.version == "2.0")
        #expect(document.entries.count == 2)
        #expect(document.directories.map(\.relativePath).contains("DCIM/100MEDIA"))
        #expect(document.rootContentDigests[.xxh64] != nil)
        #expect(document.rootStructureDigests[.xxh64] != nil)
    }

    @Test func failedTransferProducesNoPotentiallyMisleadingPartialMHL() {
        // A partial MHL beside a failed run is easy to mistake for evidence
        // that the whole card completed. Detail remains in JSON/Markdown.
        let xml = MHLWriter.xml(for: ReportFixtures.failedReport(), destination: ReportFixtures.destinationA)
        #expect(xml == nil)
    }

    @Test func destinationWithNothingVerifiedGetsNoMHL() {
        // destinationB of the failed report has one failure and one skip.
        let xml = MHLWriter.xml(for: ReportFixtures.failedReport(), destination: ReportFixtures.destinationB)
        #expect(xml == nil)
    }

    @Test func md5ReportsUseTheMD5Tag() throws {
        let report = TransferReport(
            id: ReportFixtures.transferID,
            status: .verified,
            algorithm: .md5,
            sourceRoot: ReportFixtures.source,
            destinations: [ReportFixtures.destinationA],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: [
                ItemResult(
                    item: SourceItem(relativePath: "clip.mov", size: 9),
                    sourceDigest: "900150983cd24fb0d6963f7d28e17f72",
                    outcomes: [ReportFixtures.destinationA: .verified]
                ),
            ],
            manifestLocations: [ReportFixtures.destinationA]
        )
        let mhl = try #require(MHLWriter.xml(for: report, destination: ReportFixtures.destinationA))
        #expect(mhl.contains(">900150983cd24fb0d6963f7d28e17f72</md5>"))
        #expect(!mhl.contains("<xxh64"))
    }

    @Test func xmlSpecialCharactersInPathsAreEscaped() throws {
        let report = TransferReport(
            id: ReportFixtures.transferID,
            status: .verified,
            algorithm: .xxh64,
            sourceRoot: ReportFixtures.source,
            destinations: [ReportFixtures.destinationA],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: [
                ItemResult(
                    item: SourceItem(relativePath: "ODD/<a&b> \"take\".mov", size: 1),
                    sourceDigest: "0000000000000000",
                    outcomes: [ReportFixtures.destinationA: .verified]
                ),
            ],
            manifestLocations: [ReportFixtures.destinationA]
        )
        let mhl = try #require(MHLWriter.xml(for: report, destination: ReportFixtures.destinationA))
        #expect(mhl.contains(">ODD/&lt;a&amp;b&gt; &quot;take&quot;.mov</path>"))
    }

    @Test func engineWritesMHLToVerifiedDestinationsButNotSpool() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        #expect(run.report.status == .verified)
        let history = destination.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        let chainURL = history.appendingPathComponent(MHLWriter.chainFileName)
        let chain = try MHLReader.validateChain(at: history)
        let generation = try #require(chain.entries.first)
        let mhlURL = history.appendingPathComponent(generation.path)
        let mhl = try String(contentsOf: mhlURL, encoding: .utf8)
        for spec in EngineHarness.standardFiles {
            #expect(mhl.contains(">\(spec.path)</path>"), "\(spec.path)")
        }
        #expect(FileManager.default.fileExists(atPath: chainURL.path))
        // The spool holds the manifest/report/log, not destination evidence.
        let spoolTarget = try #require(run.report.spoolLocation)
        #expect(!FileManager.default.fileExists(
            atPath: spoolTarget.appendingPathComponent(MHLWriter.directoryName).path))
    }

    @Test func readerRoundTripsSupportedHashesAndEscapedPaths() throws {
        let xml = try #require(
            MHLWriter.xml(
                for: ReportFixtures.verifiedReport(),
                destination: ReportFixtures.destinationA
            )
        )
        let document = try MHLReader.read(Data(xml.utf8))
        #expect(document.version == "2.0")
        #expect(document.entries.count == 2)
        #expect(document.entries[0].relativePath == "DCIM/100MEDIA/A001.MP4")
        #expect(document.entries[0].digests[.xxh64] == "0123456789abcdef")
    }

    @Test func c4MatchesReferenceVectors() {
        #expect(C4Checksum.digest(Data()) == "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
        #expect(C4Checksum.digest(Data("hello".utf8)) == "c447Fm3BJZQ62765jMZJH4m28hrDM7Szbj9CUmj4F4gnvyDYXYz4WfnK2nYRhFvRgYEectEXYBYWLDpLo6XGNAfKdt")
    }

    @Test func generationsAppendToValidatedChainAndArchivePriorIndex() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "history")
        let fileSystem = RealFileSystem()
        let report = ReportFixtures.verifiedReport(destinations: [destination])

        let first = try MHLHistoryStore.append(
            report: report,
            destination: destination,
            fileSystem: fileSystem
        )
        _ = try #require(first)
        let second = try MHLHistoryStore.append(
            report: report,
            destination: destination,
            fileSystem: fileSystem
        )
        _ = try #require(second)

        let directory = destination.appendingPathComponent(MHLWriter.directoryName)
        let chain = try MHLReader.validateChain(at: directory)
        #expect(chain.entries.map(\.sequence) == [1, 2])
        #expect(FileManager.default.fileExists(
            atPath: directory
                .appendingPathComponent("chain-history")
                .appendingPathComponent("ascmhl_chain_before_0002.xml").path
        ))
    }
}
