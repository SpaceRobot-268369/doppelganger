import XCTest
@testable import Doppelganger

@MainActor
final class ConnectedDisksTests: XCTestCase {
    func testCameraCardDetectionUsesSyntheticDCIMFixture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("DCIM", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(VolumeWatcher.looksLikeCard(root))
    }

    func testOrdinarySyntheticVolumeIsNotClassifiedAsCameraCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(VolumeWatcher.looksLikeCard(root))
    }

    func testMountedVolumeDerivesUsedCapacityAndHonestConnectionLabel() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/Synthetic"),
            name: "Synthetic",
            looksLikeCameraCard: false,
            fileSystem: "APFS",
            totalBytes: 1_000,
            availableBytes: 350,
            isRemovable: true,
            isEjectable: true,
            isWritable: true
        )

        XCTAssertEqual(volume.usedBytes, 650)
        XCTAssertEqual(volume.connectionDescription, "Removable media")
        XCTAssertTrue(volume.isDestinationCandidate)
        XCTAssertEqual(volume.storageCategory, .externalDisk)
    }

    func testInternalVolumeIsVisibleWithoutBeingClassifiedAsDestination() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/"),
            name: "Macintosh HD",
            looksLikeCameraCard: false,
            isInternal: true,
            isWritable: true
        )

        XCTAssertEqual(volume.connectionDescription, "Internal")
        XCTAssertFalse(volume.isDestinationCandidate)
        XCTAssertEqual(volume.storageCategory, .internalStorage)
    }

    func testRemovableFlagTakesPrecedenceOverAmbiguousInternalFlag() {
        let volume = MountedVolume(
            url: URL(fileURLWithPath: "/Volumes/SyntheticCard"),
            name: "SyntheticCard",
            looksLikeCameraCard: true,
            isRemovable: true,
            isInternal: true
        )

        XCTAssertEqual(volume.connectionDescription, "Removable media")
        XCTAssertFalse(volume.isDestinationCandidate)
        XCTAssertEqual(volume.storageCategory, .cameraCard)
    }
}
