import Foundation
import Testing
@testable import Doppelganger

struct MHLTests {
    @Test func verifiedReportProducesExactMHL() {
        // Byte-exact output: MHL files are compared and archived by other
        // tools, so encoding must be deterministic.
        let xml = MHLWriter.xml(for: ReportFixtures.verifiedReport(), destination: ReportFixtures.destinationA)
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <name>doppelganger</name>
            <tool>doppelganger</tool>
            <startdate>2025-08-09T00:40:00.000Z</startdate>
            <finishdate>2025-08-09T00:44:02.500Z</finishdate>
          </creatorinfo>
          <hash>
            <file>DCIM/100MEDIA/A001.MP4</file>
            <size>1234567</size>
            <xxhash64be>0123456789abcdef</xxhash64be>
            <hashdate>2025-08-09T00:44:02.500Z</hashdate>
          </hash>
          <hash>
            <file>DCIM/100MEDIA/A002.MP4</file>
            <size>42</size>
            <xxhash64be>fedcba9876543210</xxhash64be>
            <hashdate>2025-08-09T00:44:02.500Z</hashdate>
          </hash>
        </hashlist>

        """
        #expect(xml == expected)
    }

    @Test func onlyVerifiedItemsAtThatDestinationAreListed() throws {
        // destinationA of the failed report verified A001 but not A002: the
        // MHL must list exactly the verified item — an MHL never records
        // failures or skips.
        let xml = MHLWriter.xml(for: ReportFixtures.failedReport(), destination: ReportFixtures.destinationA)
        let mhl = try #require(xml)
        #expect(mhl.contains("<file>DCIM/100MEDIA/A001.MP4</file>"))
        #expect(!mhl.contains("A002"))
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
        #expect(mhl.contains("<md5>900150983cd24fb0d6963f7d28e17f72</md5>"))
        #expect(!mhl.contains("xxhash64be"))
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
        #expect(mhl.contains("<file>ODD/&lt;a&amp;b&gt; &quot;take&quot;.mov</file>"))
    }

    @Test func engineWritesMHLToVerifiedDestinationsButNotSpool() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "dest")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool"))

        #expect(run.report.status == .verified)
        let mhlURL = destination.appendingPathComponent(MHLWriter.fileName(shortID: run.report.shortID))
        let mhl = try String(contentsOf: mhlURL, encoding: .utf8)
        for spec in EngineHarness.standardFiles {
            #expect(mhl.contains("<file>\(spec.path)</file>"), "\(spec.path)")
        }
        // The spool holds the manifest/report/log, not destination evidence.
        let spoolTarget = try #require(run.report.spoolLocation)
        #expect(!FileManager.default.fileExists(
            atPath: spoolTarget.appendingPathComponent(MHLWriter.fileName(shortID: run.report.shortID)).path))
    }
}
