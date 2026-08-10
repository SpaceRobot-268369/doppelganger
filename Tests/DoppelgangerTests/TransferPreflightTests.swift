import Foundation
import Testing
@testable import Doppelganger

struct TransferPreflightTests {
    @Test func emptySourceAndExistingOutputAreBlocking() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeDestination(named: "empty-card")
        let destination = try fixtures.makeDestination(named: "destination")
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("Day 01"),
            withIntermediateDirectories: true
        )

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01"
        )

        #expect(!result.canStart)
        #expect(result.blockingIssues.contains { $0.contains("source is empty") })
        #expect(result.blockingIssues.contains { $0.contains("already exists") })
    }

    @Test func caseAndPathCompatibilityIssuesAreSpecific() {
        let volume = FileSystemVolume(
            identifier: "test",
            name: "Editorial SSD",
            mountPath: "/Volumes/Editorial",
            supportsCaseSensitiveNames: false,
            maximumNameBytes: 8,
            maximumPathBytes: 40
        )
        let items = [
            SourceItem(relativePath: "A/CLIP.MOV", size: 1),
            SourceItem(relativePath: "a/clip.mov", size: 1),
            SourceItem(relativePath: "folder/very-long-name.mov", size: 1),
        ]

        let issues = TransferPreflight.compatibilityIssues(
            items: items,
            output: URL(fileURLWithPath: "/Volumes/Editorial/Day 01"),
            volume: volume
        )

        #expect(issues.contains { $0.contains("case-insensitive") })
        #expect(issues.contains { $0.contains("8-byte") })
        #expect(issues.contains { $0.contains("40-byte") })
    }

    /// The review sheet renders the source's file tree from the plan the scan
    /// already produced, so it must carry the enumerated items.
    @Test func inspectionCarriesTheEnumeratedSourcePlan() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: [
            FixtureBuilder.FileSpec("DCIM/100/A001.MOV", size: 2048, seed: 1),
            FixtureBuilder.FileSpec("DCIM/100/A002.MOV", size: 4096, seed: 2),
            FixtureBuilder.FileSpec("DCIM/CLIPINFO.XML", size: 512, seed: 3),
        ])
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "Day 01"
        )

        #expect(result.items.count == result.itemCount)
        #expect(result.items.reduce(0) { $0 + $1.size } == result.totalBytes)
        #expect(Set(result.items.map(\.relativePath)) == [
            "DCIM/100/A001.MOV",
            "DCIM/100/A002.MOV",
            "DCIM/CLIPINFO.XML",
        ])
    }

    @Test func sourceTreeFoldsThePlanIntoFoldersAndCapsHugeDirectories() throws {
        let items = [
            SourceItem(relativePath: "DCIM/100/A002.MOV", size: 200),
            SourceItem(relativePath: "DCIM/100/A001.MOV", size: 100),
            SourceItem(relativePath: "DCIM/CLIPINFO.XML", size: 10),
            SourceItem(relativePath: "README.TXT", size: 1),
        ]

        let tree = SourceTreeNode.build(from: items)

        // Directories sort before files, and each rolls up its own totals.
        #expect(tree.map(\.name) == ["DCIM", "README.TXT"])
        let dcim = try #require(tree.first)
        #expect(dcim.isDirectory)
        #expect(dcim.fileCount == 3)
        #expect(dcim.byteCount == 310)
        let hundred = try #require(dcim.children?.first)
        #expect(hundred.name == "100")
        #expect(hundred.children?.map(\.name) == ["A001.MOV", "A002.MOV"])

        let many = (0..<10).map { SourceItem(relativePath: String(format: "F%03d.MOV", $0), size: 1) }
        let capped = SourceTreeNode.build(from: many, childLimit: 4)
        #expect(capped.count == 5)
        #expect(capped.last?.children == nil)
        #expect(capped.last?.fileCount == 6)
    }
}
