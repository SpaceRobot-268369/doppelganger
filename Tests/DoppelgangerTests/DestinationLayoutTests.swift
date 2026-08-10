import Foundation
import Testing
@testable import Doppelganger

/// Where a transfer's files land inside each destination, and how the transfer
/// folder is named when one is created.
struct DestinationLayoutTests {
    private static let card: [FixtureBuilder.FileSpec] = [
        FixtureBuilder.FileSpec("DCIM/100/A001.MOV", size: 2048, seed: 1),
        FixtureBuilder.FileSpec("DCIM/100/A002.MOV", size: 2048, seed: 2),
    ]

    @Test func transferFolderNameFollowsTheDateAndReelConvention() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 10
        let date = Calendar(identifier: .gregorian).date(from: components)!

        #expect(TransferPreflight.dateStamp(date) == "20260810")
        #expect(TransferPreflight.defaultFolderName(reel: "A001", at: date) == "20260810_A001")
        #expect(TransferPreflight.defaultFolderName(reel: "a001", at: date) == "20260810_A001")
        // A card carrying its own reel keeps it; one that does not takes the
        // A-camera default rather than dragging a raw folder name into the
        // convention.
        #expect(
            TransferPreflight.defaultFolderName(
                for: URL(fileURLWithPath: "/Volumes/A001"),
                at: date
            ) == "20260810_A001"
        )
        #expect(
            TransferPreflight.defaultFolderName(
                for: URL(fileURLWithPath: "/Volumes/Untitled/DCIM/100_FUJI"),
                at: date
            ) == "20260810_A001"
        )
        #expect(TransferPreflight.conventionalReel(in: "CANON_C012_01") == "C012")
        #expect(TransferPreflight.conventionalReel(in: "100_FUJI") == nil)
        #expect(TransferPreflight.defaultReel(position: 1) == "A002")
    }

    @Test func newFolderLayoutWritesUnderTheNamedFolder() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "20260810_A001",
            layout: .newFolder
        )

        #expect(result.canStart)
        #expect(result.layout == .newFolder)
        #expect(result.destinations[0].output.lastPathComponent == "20260810_A001")
        #expect(result.destinations[0].output.deletingLastPathComponent().path == destination.path)
    }

    @Test func directLayoutWritesStraightIntoTheDestination() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "",
            layout: .directly
        )

        // An empty folder name is fine when no folder is being created.
        #expect(result.canStart)
        #expect(result.layout == .directly)
        #expect(result.destinations[0].output.path == destination.path)
        #expect(result.notices.contains { $0.contains("straight into") })
    }

    /// Direct output has no empty-folder guarantee, so preflight has to look for
    /// files the transfer would collide with — the engine never overwrites.
    @Test func directLayoutBlocksWhenTheDestinationAlreadyHoldsThosePaths() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")
        let occupied = destination.appendingPathComponent("DCIM/100")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data([0x00]).write(to: occupied.appendingPathComponent("A001.MOV"))

        let result = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "",
            layout: .directly
        )

        #expect(!result.canStart)
        #expect(result.blockingIssues.contains { $0.contains("A001.MOV") })

        // The same destination is fine for a new-folder transfer.
        let inFolder = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "20260810_A001",
            layout: .newFolder
        )
        #expect(inFolder.canStart)
    }

    @Test func engineWritesDirectlyIntoTheDestinationWhenAsked() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: Self.card)
        let destination = try fixtures.makeDestination(named: "destination")
        let spool = try fixtures.makeDestination(named: "spool")

        let preflight = await TransferPreflight.inspect(
            source: source,
            destinationBases: [destination],
            folderName: "",
            layout: .directly
        )
        #expect(preflight.canStart)

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: preflight.requestDestinations.map(\.outputRoot),
            spool: spool
        )

        #expect(run.report.status == .verified)
        let manager = FileManager.default
        // No transfer-folder level: the tree starts at the destination root.
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("DCIM/100/A001.MOV").path))
        #expect(manager.fileExists(atPath: destination.appendingPathComponent("DCIM/100/A002.MOV").path))
    }
}
