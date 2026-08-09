import Foundation
import Testing
@testable import Doppelganger

/// Exercises the production file-system implementation against scratch-dir
/// fixtures only (Principle 3 — never real cards or user footage).
struct RealFileSystemTests {
    private let fs = RealFileSystem()

    @Test func enumerationIsSortedRelativeAndComplete() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("DCIM/100MEDIA/B002.MP4", size: 64, seed: 2),
            .init("DCIM/100MEDIA/A001.MP4", size: 128, seed: 1),
            .init("MISC/info.txt", size: 5, seed: 3),
            .init("root-file.bin", size: 0, seed: 4),
        ])
        let items = try fs.enumerate(root: card)
        #expect(items.map(\.relativePath) == [
            "DCIM/100MEDIA/A001.MP4",
            "DCIM/100MEDIA/B002.MP4",
            "MISC/info.txt",
            "root-file.bin",
        ])
        #expect(items.map(\.size) == [128, 64, 5, 0])
    }

    @Test func enumerationSkipsHiddenMetadataFiles() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("clip.mov", size: 10, seed: 1),
            .init(".DS_Store", size: 10, seed: 2),
            .init(".Spotlight-V100/store.db", size: 10, seed: 3),
            .init(".camera-settings", size: 10, seed: 4),
        ])
        let items = try fs.enumerate(root: card)
        #expect(items.map(\.relativePath) == [".camera-settings", "clip.mov"])
    }

    @Test func enumeratingAMissingRootThrowsVolumeGone() throws {
        let fixtures = try FixtureBuilder()
        let missing = fixtures.root.appendingPathComponent("never-created")
        #expect(throws: FileSystemError.volumeGone) {
            _ = try fs.enumerate(root: missing)
        }
    }

    @Test func writtenBytesReadBackIdentically() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "dest")
        let fileURL = destination.appendingPathComponent("out.bin")
        let payload = SplitMix64.bytes(count: 100_000, seed: 7)

        let writer = try fs.openForWritingExclusive(fileURL)
        try writer.write(payload, count: payload.count)
        try writer.close()

        // Cached and uncached reads must both return the exact bytes.
        for uncached in [false, true] {
            let reader = try fs.openForReading(fileURL, uncached: uncached)
            var buffer = [UInt8](repeating: 0, count: 4096)
            var collected: [UInt8] = []
            while true {
                let count = try reader.read(into: &buffer)
                if count == 0 { break }
                collected.append(contentsOf: buffer[0..<count])
            }
            reader.close()
            #expect(collected == payload, "uncached=\(uncached)")
        }
    }

    @Test func exclusiveCreateThrowsOnCollision() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "dest")
        let fileURL = destination.appendingPathComponent("clip.mov")
        let writer = try fs.openForWritingExclusive(fileURL)
        try writer.write([1, 2, 3], count: 3)
        try writer.close()

        #expect(throws: FileSystemError.alreadyExists) {
            _ = try fs.openForWritingExclusive(fileURL)
        }
        // The collision must not have clobbered the existing file.
        #expect(try fixtures.bytes(at: fileURL) == [1, 2, 3])
    }

    @Test func openingAMissingFileForReadingThrowsVolumeGone() throws {
        let fixtures = try FixtureBuilder()
        let missing = fixtures.root.appendingPathComponent("nope.mov")
        #expect(throws: FileSystemError.volumeGone) {
            _ = try fs.openForReading(missing, uncached: false)
        }
    }

    @Test func removeItemRemovesOnlyTheGivenFile() throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "dest")
        let keep = destination.appendingPathComponent("keep.bin")
        let remove = destination.appendingPathComponent("remove.bin")
        for url in [keep, remove] {
            let writer = try fs.openForWritingExclusive(url)
            try writer.write([9], count: 1)
            try writer.close()
        }
        try fs.removeItem(at: remove)
        #expect(!fs.fileExists(at: remove))
        #expect(fs.fileExists(at: keep))
    }

    @Test func createDirectoryIsRecursiveAndIdempotent() throws {
        let fixtures = try FixtureBuilder()
        let nested = fixtures.root.appendingPathComponent("a/b/c", isDirectory: true)
        try fs.createDirectory(at: nested)
        try fs.createDirectory(at: nested)
        #expect(fs.fileExists(at: nested))
    }

    @Test func freeSpaceIsPositiveForTheScratchVolume() throws {
        let fixtures = try FixtureBuilder()
        #expect(try fs.freeSpace(at: fixtures.root) > 0)
    }
}
