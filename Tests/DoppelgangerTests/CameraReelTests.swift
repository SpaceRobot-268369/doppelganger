import Foundation
import Testing
@testable import Doppelganger

/// Cameras and the reel/tape naming they own: A001, A002 for the A camera,
/// B001 for the B camera.
struct CameraReelTests {
    @Test func reelLettersAreNormalizedAndTapeNamesFollowTheConvention() {
        #expect(CameraRecord.normalizedPrefix(" a ") == "A")
        #expect(CameraRecord.normalizedPrefix("bb1") == "BB")
        #expect(CameraRecord.normalizedPrefix("123") == "")

        let camera = CameraRecord(projectID: UUID(), reelPrefix: "a", name: "A Camera")
        #expect(camera.reelPrefix == "A")
        #expect(camera.reelName(number: 1) == "A001")
        #expect(camera.reelName(number: 27) == "A027")
        #expect(camera.reelName(number: 0) == "A001")
        #expect(camera.displayName == "A Camera")
    }

    @Test func tapeNumbersAreReadBackOnlyFromMatchingReelNames() {
        let cameraA = CameraRecord(projectID: UUID(), reelPrefix: "A", name: "A Camera")
        #expect(cameraA.tapeNumber(inReelName: "A004") == 4)
        #expect(cameraA.tapeNumber(inReelName: "a004") == 4)
        #expect(cameraA.tapeNumber(inReelName: "B004") == nil)
        #expect(cameraA.tapeNumber(inReelName: "A00X") == nil)
        #expect(cameraA.tapeNumber(inReelName: "A") == nil)
    }

    @Test func cameraWithoutANameStillIdentifiesItselfByReelLetter() {
        let camera = CameraRecord(projectID: UUID(), reelPrefix: "C", name: "")
        #expect(camera.displayName == "C Camera")
        #expect(camera.hardwareDescription.isEmpty)

        let described = CameraRecord(
            projectID: UUID(), reelPrefix: "B", name: "B Camera",
            make: "ARRI", model: "ALEXA 35"
        )
        #expect(described.hardwareDescription == "ARRI ALEXA 35")
    }

    @MainActor
    @Test func reelLettersAreUniquePerProjectAndArchivingFreesThem() throws {
        let store = try makeStore()
        store.createProject(name: "Feature")
        let project = try #require(store.projects.first)

        #expect(store.createCamera(projectID: project.id, reelPrefix: "A", name: "A Camera") != nil)
        // A second camera cannot claim a reel letter already in use.
        #expect(store.createCamera(projectID: project.id, reelPrefix: "a", name: "Second") == nil)
        #expect(store.lastError != nil)
        store.clearError()
        #expect(store.createCamera(projectID: project.id, reelPrefix: "B", name: "B Camera") != nil)
        #expect(store.cameras(for: project.id).map(\.reelPrefix) == ["A", "B"])

        let cameraB = try #require(store.cameras(for: project.id).first { $0.reelPrefix == "B" })
        store.archiveCamera(cameraB)
        #expect(store.cameras(for: project.id).map(\.reelPrefix) == ["A"])
        #expect(store.createCamera(projectID: project.id, reelPrefix: "B", name: "Reused") != nil)
    }

    @MainActor
    @Test func nextReelNameContinuesTheRunThatCameraAlreadyOffloaded() throws {
        let store = try makeStore()
        store.createProject(name: "Feature")
        let project = try #require(store.projects.first)
        let camera = try #require(
            store.createCamera(projectID: project.id, reelPrefix: "A", name: "A Camera")
        )

        #expect(store.suggestedReelName(for: camera) == "A001")

        let root = URL(fileURLWithPath: "/tmp/doppelganger-camera-test")
        for reel in ["A001", "A002"] {
            let id = UUID()
            store.registerTask(
                id: id,
                label: reel,
                source: root.appendingPathComponent(reel),
                destinations: [root.appendingPathComponent("dest")],
                projectID: project.id,
                algorithm: .xxh3,
                verificationProfile: .standard
            )
            store.updateTaskOrganization(
                taskID: id,
                projectID: project.id,
                shootingDay: "Day 01",
                cameraLabel: camera.displayName,
                cardLabel: reel
            )
        }

        #expect(store.suggestedReelName(for: camera) == "A003")

        // Another camera's reels never advance this one's run.
        let cameraB = try #require(
            store.createCamera(projectID: project.id, reelPrefix: "B", name: "B Camera")
        )
        #expect(store.suggestedReelName(for: cameraB) == "B001")
    }

    @MainActor
    private func makeStore() throws -> ProductStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-camera-\(UUID().uuidString)", isDirectory: true)
        return ProductStore(
            database: try ProductDatabase(inMemory: true),
            avatars: AvatarStore(root: root),
            spoolRoot: nil
        )
    }
}
