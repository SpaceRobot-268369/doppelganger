import Foundation

private struct SettingsPackage: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let activeProfileID: UUID
    let settings: SettingsValues
    let profiles: [ExportedProfile]
    let workflowLibrary: WorkflowLibrarySnapshot
}

private struct ExportedProfile: Codable {
    let profile: OperatorProfile
    let avatarPNG: Data?
}

private struct SettingsValues: Codable {
    let autoShowLog: Bool
    let maxConcurrent: Int
    let appearance: AppearancePreference
    let checksum: ChecksumAlgorithm
    let verificationProfile: VerificationProfile
    let automaticCameraDetection: Bool
    let automaticContactSheet: Bool
}

@MainActor
enum SettingsPackageService {
    static let fileExtension = "doppelgangersettings"

    static func export(
        to url: URL,
        store: ProductStore,
        workflowLibrary: WorkflowLibraryStore,
        defaults: UserDefaults = .standard
    ) throws {
        let maxConcurrent = defaults.integer(forKey: AppModel.maxConcurrentKey)
        let package = SettingsPackage(
            schemaVersion: SettingsPackage.currentSchemaVersion,
            exportedAt: Date(),
            activeProfileID: store.activeProfile.id,
            settings: SettingsValues(
                autoShowLog: defaults.bool(forKey: "prefs.autoShowLog"),
                maxConcurrent: maxConcurrent == 0 ? AppModel.defaultMaxConcurrent : maxConcurrent,
                appearance: AppearancePreference(
                    rawValue: defaults.string(forKey: AppearancePreference.storageKey) ?? ""
                ) ?? .system,
                checksum: ChecksumAlgorithm(
                    rawValue: defaults.string(forKey: AppModel.checksumAlgorithmKey) ?? ""
                ) ?? .xxh3,
                verificationProfile: VerificationProfile(
                    rawValue: defaults.string(forKey: AppModel.verificationProfileKey) ?? ""
                ) ?? .standard,
                automaticCameraDetection: defaults.bool(forKey: AppModel.automaticCameraDetectionKey),
                automaticContactSheet: defaults.bool(forKey: AppModel.automaticContactSheetKey)
            ),
            profiles: store.profiles.map { profile in
                ExportedProfile(
                    profile: profile,
                    avatarPNG: store.avatars.data(for: profile.avatar.imageFileName)
                )
            },
            workflowLibrary: workflowLibrary.snapshot
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(package).write(to: url, options: .atomic)
    }

    static func importPackage(
        from url: URL,
        store: ProductStore,
        workflowLibrary: WorkflowLibraryStore,
        defaults: UserDefaults = .standard
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(SettingsPackage.self, from: Data(contentsOf: url))
        guard package.schemaVersion == SettingsPackage.currentSchemaVersion else {
            throw SettingsPackageError.unsupportedSchema(package.schemaVersion)
        }
        try store.importProfiles(
            package.profiles.map { ($0.profile, $0.avatarPNG) },
            activeProfileID: package.activeProfileID
        )
        workflowLibrary.replace(with: package.workflowLibrary)
        defaults.set(package.settings.autoShowLog, forKey: "prefs.autoShowLog")
        defaults.set(package.settings.maxConcurrent, forKey: AppModel.maxConcurrentKey)
        defaults.set(package.settings.appearance.rawValue, forKey: AppearancePreference.storageKey)
        defaults.set(package.settings.checksum.rawValue, forKey: AppModel.checksumAlgorithmKey)
        defaults.set(package.settings.verificationProfile.rawValue, forKey: AppModel.verificationProfileKey)
        defaults.set(package.settings.automaticCameraDetection, forKey: AppModel.automaticCameraDetectionKey)
        defaults.set(package.settings.automaticContactSheet, forKey: AppModel.automaticContactSheetKey)
    }
}

enum SettingsPackageError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            L10n.format("This settings package uses unsupported schema version %lld.", Int64(version))
        }
    }
}
