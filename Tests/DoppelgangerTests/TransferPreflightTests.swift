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
}
