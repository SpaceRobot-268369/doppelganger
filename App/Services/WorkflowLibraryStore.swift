import Foundation
import Observation

enum DestinationRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary = "Primary"
    case backup = "Backup"
    case shuttle = "Shuttle"
    case archive = "Archive"

    var id: String { rawValue }
    var displayName: String { L10n.text(rawValue) }
}

struct LogicalDestination: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var role: DestinationRole
    var volumeIdentifier: String?
    var volumeName: String?
    var lastAvailableBytes: Int64?
    var totalBytes: Int64?
    var lastSeenAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        role: DestinationRole,
        volumeIdentifier: String? = nil,
        volumeName: String? = nil,
        lastAvailableBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.role = role
        self.volumeIdentifier = volumeIdentifier
        self.volumeName = volumeName
        self.lastAvailableBytes = lastAvailableBytes
        self.totalBytes = totalBytes
        self.lastSeenAt = lastSeenAt
    }
}

struct DestinationGroupRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var destinationIDs: [UUID]

    init(id: UUID = UUID(), name: String, destinationIDs: [UUID]) {
        self.id = id
        self.name = name
        self.destinationIDs = destinationIDs
    }
}

struct NamingTemplateRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var pattern: String

    init(id: UUID = UUID(), name: String, pattern: String) {
        self.id = id
        self.name = name
        self.pattern = pattern
    }
}

struct TransferPresetRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var version: Int
    var verificationProfile: VerificationProfile
    var destinationGroupID: UUID?
    var namingTemplateID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        version: Int = 1,
        verificationProfile: VerificationProfile,
        destinationGroupID: UUID?,
        namingTemplateID: UUID?
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.verificationProfile = verificationProfile
        self.destinationGroupID = destinationGroupID
        self.namingTemplateID = namingTemplateID
    }
}

struct WorkflowLibrarySnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion = currentSchemaVersion
    var destinations: [LogicalDestination] = []
    var groups: [DestinationGroupRecord] = []
    var templates: [NamingTemplateRecord] = [
        NamingTemplateRecord(name: "Date + Source", pattern: "{date}_{source}")
    ]
    var presets: [TransferPresetRecord] = []
}

@MainActor
@Observable
final class WorkflowLibraryStore {
    static let defaultsKey = "workflowLibrary.v1"
    private(set) var snapshot: WorkflowLibrarySnapshot
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(WorkflowLibrarySnapshot.self, from: data),
           decoded.schemaVersion == WorkflowLibrarySnapshot.currentSchemaVersion {
            snapshot = decoded
        } else {
            snapshot = WorkflowLibrarySnapshot()
        }
    }

    var destinations: [LogicalDestination] { snapshot.destinations }
    var groups: [DestinationGroupRecord] { snapshot.groups }
    var templates: [NamingTemplateRecord] { snapshot.templates }
    var presets: [TransferPresetRecord] { snapshot.presets }

    func addDestination(url: URL, role: DestinationRole) {
        let path = url.standardizedFileURL.path
        if let index = snapshot.destinations.firstIndex(where: { $0.path == path }) {
            observeDestination(at: index, url: url)
            save()
            return
        }
        var destination = LogicalDestination(
            name: url.lastPathComponent,
            path: path,
            role: role
        )
        observeDestination(&destination, url: url)
        snapshot.destinations.append(destination)
        save()
    }

    func updateRole(_ destination: LogicalDestination, role: DestinationRole) {
        guard let index = snapshot.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        snapshot.destinations[index].role = role
        save()
    }

    func refreshDestination(_ destination: LogicalDestination) {
        guard let index = snapshot.destinations.firstIndex(where: { $0.id == destination.id }) else { return }
        observeDestination(at: index, url: URL(fileURLWithPath: destination.path))
        save()
    }

    func removeDestination(_ destination: LogicalDestination) {
        snapshot.destinations.removeAll { $0.id == destination.id }
        for index in snapshot.groups.indices {
            snapshot.groups[index].destinationIDs.removeAll { $0 == destination.id }
        }
        save()
    }

    func addGroup(name: String, destinationIDs: [UUID]) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !destinationIDs.isEmpty else { return }
        snapshot.groups.append(DestinationGroupRecord(name: value, destinationIDs: destinationIDs))
        save()
    }

    func addTemplate(name: String, pattern: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, NamingTemplateRenderer.validate(value) else { return }
        snapshot.templates.append(NamingTemplateRecord(name: title, pattern: value))
        save()
    }

    func addPreset(
        name: String,
        verificationProfile: VerificationProfile,
        groupID: UUID?,
        templateID: UUID?
    ) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        snapshot.presets.append(TransferPresetRecord(
            name: value,
            verificationProfile: verificationProfile,
            destinationGroupID: groupID,
            namingTemplateID: templateID
        ))
        save()
    }

    func destinations(in group: DestinationGroupRecord) -> [LogicalDestination] {
        group.destinationIDs.compactMap { id in destinations.first { $0.id == id } }
    }

    func replace(with imported: WorkflowLibrarySnapshot) {
        guard imported.schemaVersion == WorkflowLibrarySnapshot.currentSchemaVersion else { return }
        snapshot = imported
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private func observeDestination(at index: Int, url: URL) {
        var destination = snapshot.destinations[index]
        observeDestination(&destination, url: url)
        snapshot.destinations[index] = destination
    }

    private func observeDestination(_ destination: inout LogicalDestination, url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let volume = try? RealFileSystem().volume(at: url)
        else { return }
        destination.name = url.lastPathComponent
        destination.path = url.standardizedFileURL.path
        destination.volumeIdentifier = volume.identifier
        destination.volumeName = volume.name
        destination.lastAvailableBytes = volume.availableBytes
        destination.totalBytes = volume.totalBytes
        destination.lastSeenAt = Date()
    }
}

enum NamingTemplateRenderer {
    private static let tokens = [
        "{date}", "{project}", "{day}", "{camera}", "{card}",
        "{source}", "{operator}", "{counter}"
    ]

    static func validate(_ pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        var stripped = pattern
        for token in tokens { stripped = stripped.replacingOccurrences(of: token, with: "") }
        return !stripped.contains("{") && !stripped.contains("}")
    }

    static func render(
        _ pattern: String,
        date: Date = Date(),
        project: String?,
        source: String?,
        shootingDay: String? = nil,
        camera: String? = nil,
        card: String? = nil,
        operatorName: String,
        counter: Int
    ) -> String {
        let dateValue = String(date.formatted(.iso8601).prefix(10))
        return TransferPreflight.validFolderName(
            pattern
                .replacingOccurrences(of: "{date}", with: dateValue)
                .replacingOccurrences(of: "{project}", with: project ?? "NO-PROJECT")
                .replacingOccurrences(of: "{day}", with: optionalToken(shootingDay, fallback: "DAY"))
                .replacingOccurrences(of: "{camera}", with: optionalToken(camera, fallback: "CAMERA"))
                .replacingOccurrences(of: "{card}", with: optionalToken(card, fallback: "CARD"))
                .replacingOccurrences(of: "{source}", with: source?.uppercased() ?? "SOURCE")
                .replacingOccurrences(of: "{operator}", with: operatorName)
                .replacingOccurrences(of: "{counter}", with: String(format: "%03d", counter))
        )
    }

    private static func optionalToken(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
