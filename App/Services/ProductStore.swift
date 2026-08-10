import Foundation
import Observation

@MainActor
@Observable
final class ProductStore {
    private(set) var profiles: [OperatorProfile]
    private(set) var activeProfile: OperatorProfile
    private(set) var projects: [ProjectRecord] = []
    private(set) var cameras: [CameraRecord] = []
    private(set) var taskHistory: [TaskHistoryRecord] = []
    private(set) var lastError: String?

    private let database: ProductDatabase?
    let avatars: AvatarStore

    init(
        database: ProductDatabase? = nil,
        avatars: AvatarStore = AvatarStore(),
        spoolRoot: URL? = TransferSession.spoolDirectory
    ) {
        self.avatars = avatars
        var resolvedDatabase = database
        var initialError: String?
        if resolvedDatabase == nil {
            do {
                resolvedDatabase = try ProductDatabase.applicationDefault()
            } catch {
                initialError = L10n.format(
                    "The product catalog could not be opened. Changes will last for this launch only: %@",
                    error.localizedDescription
                )
            }
        }
        self.database = resolvedDatabase
        let fallback = OperatorProfile(displayName: "Local Operator")
        if let resolvedDatabase {
            do {
                profiles = try resolvedDatabase.profiles()
                activeProfile = try resolvedDatabase.activeProfile()
                if let spoolRoot {
                    try resolvedDatabase.importSpoolManifests(
                        at: spoolRoot,
                        fallbackProfile: activeProfile
                    )
                }
                projects = try resolvedDatabase.projects()
                cameras = try resolvedDatabase.cameras()
                taskHistory = try resolvedDatabase.taskHistory()
            } catch {
                profiles = [fallback]
                activeProfile = fallback
                initialError = error.localizedDescription
            }
        } else {
            profiles = [fallback]
            activeProfile = fallback
        }
        lastError = initialError
    }

    func clearError() {
        lastError = nil
    }

    func reportError(_ message: String) {
        lastError = message
    }

    func createProfile(displayName: String, colorHex: String = "4A90E2") {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile = OperatorProfile(
            displayName: name,
            avatar: OperatorAvatar(colorHex: colorHex)
        )
        do {
            try database?.saveProfile(profile)
            profiles.append(profile)
            profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            activate(profile)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateProfile(_ profile: OperatorProfile, displayName: String, colorHex: String? = nil) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = profile
        updated.displayName = name
        if let colorHex { updated.avatar.colorHex = colorHex }
        updated.updatedAt = Date()
        saveAndReload(updated)
    }

    func importAvatar(from source: URL, for profile: OperatorProfile) {
        do {
            let fileName = try avatars.importImage(from: source, profileID: profile.id)
            var updated = profile
            updated.avatar.kind = .image
            updated.avatar.imageFileName = fileName
            updated.updatedAt = Date()
            saveAndReload(updated)
        } catch {
            lastError = L10n.format("Avatar could not be imported: %@", error.localizedDescription)
        }
    }

    func useInitialsAvatar(for profile: OperatorProfile, colorHex: String) {
        var updated = profile
        updated.avatar = OperatorAvatar(kind: .initials, colorHex: colorHex)
        updated.updatedAt = Date()
        saveAndReload(updated)
    }

    func activate(_ profile: OperatorProfile) {
        guard !profile.isArchived else { return }
        do {
            try database?.setActiveProfile(id: profile.id)
            activeProfile = profile
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archive(_ profile: OperatorProfile) {
        guard profiles.count > 1 else {
            lastError = L10n.text("At least one operator profile must remain active.")
            return
        }
        do {
            try database?.archiveProfile(id: profile.id)
            profiles.removeAll { $0.id == profile.id }
            if activeProfile.id == profile.id, let first = profiles.first {
                activate(first)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createProject(
        name: String,
        notes: String = "",
        productionCompany: String = "",
        shootLocation: String = "",
        shootStartDate: Date? = nil,
        shootEndDate: Date? = nil
    ) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let project = ProjectRecord(
            name: value,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            productionCompany: productionCompany.trimmingCharacters(in: .whitespacesAndNewlines),
            shootLocation: shootLocation.trimmingCharacters(in: .whitespacesAndNewlines),
            shootStartDate: shootStartDate,
            shootEndDate: shootEndDate
        )
        do {
            try database?.saveProject(project)
            projects.append(project)
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateProject(_ project: ProjectRecord) {
        var updated = project
        updated.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = project.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.productionCompany = project.productionCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.shootLocation = project.shootLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return }
        do {
            try database?.saveProject(updated)
            if let index = projects.firstIndex(where: { $0.id == updated.id }) {
                projects[index] = updated
            }
            projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            reloadTaskHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Cameras

    /// The project's cameras, in reel order — A before B before C.
    func cameras(for projectID: UUID?) -> [CameraRecord] {
        guard let projectID else { return [] }
        return cameras.filter { $0.projectID == projectID && $0.archivedAt == nil }
    }

    @discardableResult
    func createCamera(
        projectID: UUID,
        reelPrefix: String,
        name: String,
        make: String = "",
        model: String = "",
        notes: String = ""
    ) -> CameraRecord? {
        let prefix = CameraRecord.normalizedPrefix(reelPrefix)
        guard !prefix.isEmpty else {
            lastError = L10n.text("A camera needs a reel letter, for example A or B.")
            return nil
        }
        guard !cameras(for: projectID).contains(where: { $0.reelPrefix == prefix }) else {
            lastError = L10n.format("Reel letter %@ is already used by another camera on this project.", prefix)
            return nil
        }
        let camera = CameraRecord(
            projectID: projectID,
            reelPrefix: prefix,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            make: make.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            try database?.saveCamera(camera)
            cameras.append(camera)
            sortCameras()
            return camera
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateCamera(_ camera: CameraRecord) {
        var updated = camera
        updated.reelPrefix = CameraRecord.normalizedPrefix(camera.reelPrefix)
        updated.name = camera.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.make = camera.make.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = camera.model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.notes = camera.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.reelPrefix.isEmpty else {
            lastError = L10n.text("A camera needs a reel letter, for example A or B.")
            return
        }
        guard !cameras(for: updated.projectID).contains(where: {
            $0.id != updated.id && $0.reelPrefix == updated.reelPrefix
        }) else {
            lastError = L10n.format(
                "Reel letter %@ is already used by another camera on this project.",
                updated.reelPrefix
            )
            return
        }
        do {
            try database?.saveCamera(updated)
            if let index = cameras.firstIndex(where: { $0.id == updated.id }) {
                cameras[index] = updated
            }
            sortCameras()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Archiving keeps every past transfer's camera and reel labels intact; it
    /// only removes the camera from future selection.
    func archiveCamera(_ camera: CameraRecord) {
        do {
            try database?.archiveCamera(id: camera.id)
            cameras.removeAll { $0.id == camera.id }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The next reel/tape name for a camera — one past the highest tape number
    /// this camera has already offloaded, or its first reel.
    func suggestedReelName(for camera: CameraRecord) -> String {
        let used = taskHistory.compactMap { task -> Int? in
            guard task.projectID == camera.projectID else { return nil }
            guard let card = task.cardLabel else { return nil }
            return camera.tapeNumber(inReelName: card)
        }
        return camera.reelName(number: (used.max() ?? 0) + 1)
    }

    private func sortCameras() {
        cameras.sort {
            if $0.reelPrefix != $1.reelPrefix {
                return $0.reelPrefix.localizedCaseInsensitiveCompare($1.reelPrefix) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func registerTask(
        id: UUID,
        label: String,
        source: URL,
        destinations: [URL],
        projectID: UUID?,
        sourceFingerprint: String? = nil,
        sourceVolumeIdentifier: String? = nil,
        sourceVolumeName: String? = nil,
        operatorProfile: OperatorProfile? = nil,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile
    ) {
        do {
            try database?.registerTask(
                id: id,
                label: label,
                source: source,
                destinations: destinations,
                projectID: projectID,
                sourceFingerprint: sourceFingerprint,
                sourceVolumeIdentifier: sourceVolumeIdentifier,
                sourceVolumeName: sourceVolumeName,
                operatorProfile: operatorProfile ?? activeProfile,
                algorithm: algorithm,
                verificationProfile: verificationProfile
            )
            reloadTaskHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerAttempt(
        id: UUID,
        taskID: UUID,
        parentAttemptID: UUID? = nil,
        kind: TransferAttemptKind,
        algorithm: ChecksumAlgorithm,
        verificationProfile: VerificationProfile,
        operatorProfile: OperatorProfile? = nil
    ) {
        do {
            try database?.registerAttempt(
                id: id,
                taskID: taskID,
                parentAttemptID: parentAttemptID,
                kind: kind,
                operatorProfile: operatorProfile ?? activeProfile,
                algorithm: algorithm,
                verificationProfile: verificationProfile
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func finishAttempt(
        id: UUID,
        taskID: UUID,
        report: TransferReport,
        verificationProfile: VerificationProfile
    ) {
        do {
            try database?.finishAttempt(
                id: id,
                taskID: taskID,
                report: report,
                verificationProfile: verificationProfile
            )
            reloadTaskHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func auditEvents(taskID: UUID? = nil) -> [AuditEventRecord] {
        do {
            return try database?.auditEvents(taskID: taskID) ?? []
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func attemptHistory(taskID: UUID) -> [AttemptHistoryRecord] {
        do {
            return try database?.attemptHistory(taskID: taskID) ?? []
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func evidenceArtifacts(taskID: UUID) -> [EvidenceArtifactHistoryRecord] {
        do {
            return try database?.evidenceArtifacts(taskID: taskID) ?? []
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    func updateTaskOrganization(
        taskID: UUID,
        projectID: UUID?,
        shootingDay: String?,
        cameraLabel: String?,
        cardLabel: String?
    ) {
        do {
            try database?.updateTaskOrganization(
                taskID: taskID,
                projectID: projectID,
                shootingDay: shootingDay,
                cameraLabel: cameraLabel,
                cardLabel: cardLabel,
                operatorProfile: activeProfile
            )
            reloadTaskHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func recordAudit(_ event: AuditEventRecord) {
        do {
            try database?.recordAudit(event)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importProfiles(
        _ importedProfiles: [(profile: OperatorProfile, avatarData: Data?)],
        activeProfileID: UUID?
    ) throws {
        guard !importedProfiles.isEmpty else { return }
        for entry in importedProfiles {
            var profile = entry.profile
            profile.archivedAt = nil
            if let avatarData = entry.avatarData {
                let fileName = try avatars.importImageData(avatarData, profileID: profile.id)
                profile.avatar.kind = .image
                profile.avatar.imageFileName = fileName
            }
            try database?.saveProfile(profile)
        }
        if let activeProfileID,
           importedProfiles.contains(where: { $0.profile.id == activeProfileID }) {
            try database?.setActiveProfile(id: activeProfileID)
        }
        if let database {
            profiles = try database.profiles()
            activeProfile = try database.activeProfile()
        } else {
            profiles = importedProfiles.map(\.profile)
            activeProfile = profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
        }
    }

    private func saveAndReload(_ profile: OperatorProfile) {
        do {
            try database?.saveProfile(profile)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            }
            if activeProfile.id == profile.id { activeProfile = profile }
            profiles.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func reloadTaskHistory() {
        guard let database else { return }
        do {
            taskHistory = try database.taskHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
