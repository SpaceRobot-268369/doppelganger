import Foundation
import Testing
@testable import Doppelganger

struct ProductDatabaseTests {
    @Test func projectProductionDetailsRoundTripAndUpdate() throws {
        let database = try ProductDatabase(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_786_000_000)
        let end = start.addingTimeInterval(86_400 * 4)
        var project = ProjectRecord(
            name: "North Shore",
            notes: "Coastal unit photography",
            productionCompany: "Example Pictures",
            shootLocation: "South Australia",
            shootStartDate: start,
            shootEndDate: end
        )
        try database.saveProject(project)

        project.name = "North Shore Unit 2"
        project.shootLocation = "Kangaroo Island"
        try database.saveProject(project)

        let saved = try #require(database.projects().first)
        #expect(saved.name == "North Shore Unit 2")
        #expect(saved.notes == "Coastal unit photography")
        #expect(saved.productionCompany == "Example Pictures")
        #expect(saved.shootLocation == "Kangaroo Island")
        #expect(saved.shootStartDate == start)
        #expect(saved.shootEndDate == end)
    }

    @Test func profilesAreMultipleLocalOperatorsAndOneMustRemain() throws {
        let database = try ProductDatabase(inMemory: true)
        let initial = try database.activeProfile()
        let second = OperatorProfile(
            displayName: "DIT Two",
            avatar: OperatorAvatar(colorHex: "FF9500")
        )
        try database.saveProfile(second)
        try database.setActiveProfile(id: second.id)

        #expect(try database.profiles().count == 2)
        #expect(try database.activeProfile().id == second.id)

        try database.archiveProfile(id: second.id)
        #expect(try database.activeProfile().id == initial.id)
        #expect(throws: (any Error).self) {
            try database.archiveProfile(id: initial.id)
        }
    }

    @Test func taskHistoryKeepsOperatorSnapshotAfterProfileRename() throws {
        let database = try ProductDatabase(inMemory: true)
        var operatorProfile = try database.activeProfile()
        operatorProfile.displayName = "Alex Original"
        try database.saveProfile(operatorProfile)
        let project = ProjectRecord(name: "Feature A")
        try database.saveProject(project)
        let taskID = UUID()
        try database.registerTask(
            id: taskID,
            label: "A001_C001",
            source: URL(fileURLWithPath: "/synthetic/card"),
            destinations: [URL(fileURLWithPath: "/synthetic/backup-a")],
            projectID: project.id,
            operatorProfile: operatorProfile,
            algorithm: .xxh3,
            verificationProfile: .standard
        )

        operatorProfile.displayName = "Alex Renamed"
        operatorProfile.updatedAt = Date()
        try database.saveProfile(operatorProfile)

        let task = try #require(database.taskHistory().first)
        #expect(task.projectName == "Feature A")
        #expect(task.operatorSnapshot.displayName == "Alex Original")
        let created = try #require(
            database.auditEvents(taskID: taskID).first { $0.action == .taskCreated }
        )
        #expect(created.operatorSnapshot?.displayName == "Alex Original")
    }

    @Test func taskOrganizationIsMutableCatalogDataWithAnAuditTrail() throws {
        let database = try ProductDatabase(inMemory: true)
        let operatorProfile = try database.activeProfile()
        let project = ProjectRecord(name: "Feature B")
        try database.saveProject(project)
        let taskID = UUID()
        try database.registerTask(
            id: taskID,
            label: "B003_C007",
            source: URL(fileURLWithPath: "/synthetic/card"),
            destinations: [URL(fileURLWithPath: "/synthetic/backup-a")],
            projectID: nil,
            operatorProfile: operatorProfile,
            algorithm: .xxh3,
            verificationProfile: .standard
        )

        try database.updateTaskOrganization(
            taskID: taskID,
            projectID: project.id,
            shootingDay: " Day 03 ",
            cameraLabel: "A Camera",
            cardLabel: "C007",
            operatorProfile: operatorProfile
        )

        let task = try #require(database.taskHistory().first)
        #expect(task.projectName == "Feature B")
        #expect(task.shootingDay == "Day 03")
        #expect(task.cameraLabel == "A Camera")
        #expect(task.cardLabel == "C007")
        let event = try #require(
            database.auditEvents(taskID: taskID).first { $0.action == .taskOrganizationChanged }
        )
        #expect(event.operatorSnapshot?.profileID == operatorProfile.id)
    }

    @Test func completedAttemptIndexesFilesEvidenceAndSearchText() throws {
        let database = try ProductDatabase(inMemory: true)
        let operatorProfile = try database.activeProfile()
        let taskID = UUID()
        let attemptID = UUID()
        try database.registerTask(
            id: taskID,
            label: "Indexed Transfer",
            source: ReportFixtures.source,
            destinations: [ReportFixtures.destinationA, ReportFixtures.destinationB],
            projectID: nil,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        try database.registerAttempt(
            id: attemptID,
            taskID: taskID,
            kind: .copy,
            operatorProfile: operatorProfile,
            algorithm: .xxh64,
            verificationProfile: .standard
        )
        try database.finishAttempt(
            id: attemptID,
            taskID: taskID,
            report: ReportFixtures.verifiedReport(),
            verificationProfile: .standard
        )

        let attempt = try #require(database.attemptHistory(taskID: taskID).first)
        #expect(attempt.fileCount == 2)
        #expect(attempt.verdict == .verified)
        let evidence = try database.evidenceArtifacts(taskID: taskID)
        #expect(evidence.count == 4)
        #expect(evidence.allSatisfy { $0.status == "written" })
        let task = try #require(database.taskHistory().first)
        #expect(task.searchableAttemptText.contains("verified"))
        #expect(task.searchableEvidenceText.contains("json-manifest"))
    }

    @Test func existingSpoolManifestImportIsReadOnlyAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-spool-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        let manifestURL = root.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: String(manifest.transferID.prefix(8)))
        )
        let bytes = try ManifestWriter.jsonData(for: manifest)
        try bytes.write(to: manifestURL, options: .withoutOverwriting)

        let database = try ProductDatabase(inMemory: true)
        let profile = try database.activeProfile()
        try database.importSpoolManifests(at: root, fallbackProfile: profile)
        try database.importSpoolManifests(at: root, fallbackProfile: profile)

        let history = try database.taskHistory()
        let task = try #require(history.first)
        #expect(history.count == 1)
        let attempts = try database.attemptHistory(taskID: task.id)
        #expect(attempts.count == 1)
        #expect(attempts.first?.fileCount == manifest.items.count)
        #expect(try database.evidenceArtifacts(taskID: task.id).count == 1)
        #expect(try Data(contentsOf: manifestURL) == bytes)
        #expect(try database.auditEvents(taskID: task.id).count == 1)
    }
}
