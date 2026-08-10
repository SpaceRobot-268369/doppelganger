import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General"
    case transfer = "Transfer"
    case verification = "Verification"
    case workflow = "Workflow"
    case profiles = "Profiles"
    case reports = "Reports"
    case data = "Data"

    var id: String { rawValue }
}

/// Dedicated in-app Settings tab selected from the sidebar or with ⌘,.
struct PreferencesView: View {
    @Bindable var model: AppModel
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false
    @AppStorage(AppModel.maxConcurrentKey) private var maxConcurrent = AppModel.defaultMaxConcurrent
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system
    @AppStorage(AppModel.checksumAlgorithmKey) private var checksum = ChecksumAlgorithm.xxh3
    @AppStorage(AppModel.verificationProfileKey) private var verificationProfile = VerificationProfile.standard
    @AppStorage(AppModel.automaticCameraDetectionKey) private var automaticCameraDetection = false
    @AppStorage(AppModel.automaticContactSheetKey) private var automaticContactSheet = false

    @State private var page = SettingsPage.general
    @State private var newProfileName = ""
    @State private var selectedProfileID: UUID?
    @State private var editedProfileName = ""
    @State private var editedColor = "4A90E2"
    @State private var importingAvatar = false
    @State private var settingsMessage: String?
    @State private var destinationRole = DestinationRole.backup
    @State private var groupName = ""
    @State private var templateName = ""
    @State private var templatePattern = "{date}_{project}_{source}"
    @State private var presetName = ""
    @State private var presetVerification = VerificationProfile.standard
    @State private var presetGroupID: UUID?
    @State private var presetTemplateID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal, 24)
                .padding(.top, 20)

            HStack(spacing: 10) {
                ForEach(SettingsPage.allCases) { item in
                    SubtabFilterChip(item.rawValue, isSelected: page == item) {
                        page = item
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch page {
                    case .general: generalSettings
                    case .transfer: transferSettings
                    case .verification: verificationSettings
                    case .workflow: workflowSettings
                    case .profiles: profileSettings
                    case .reports: reportSettings
                    case .data: dataSettings
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(appearance.colorScheme)
        .fileImporter(isPresented: $importingAvatar, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let selectedProfile else { return }
            model.productStore.importAvatar(from: url, for: selectedProfile)
        }
        .onAppear {
            if selectedProfileID == nil { select(model.productStore.activeProfile) }
        }
    }

    private var selectedProfile: OperatorProfile? {
        model.productStore.profiles.first { $0.id == selectedProfileID }
    }

    private var generalSettings: some View {
        Group {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Appearance", "Follows the system unless you choose a fixed appearance.")
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Label(option.title, systemImage: option.icon).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            card {
                Toggle(isOn: $autoShowLog) {
                    heading("Open the log automatically", "Expand the live log when a new transfer starts.")
                }
            }
        }
    }

    private var transferSettings: some View {
        Group {
            card {
                Stepper(value: $maxConcurrent, in: 1...4) {
                    heading(
                        "Simultaneous transfers: \(maxConcurrent)",
                        "Resource-conflicting tasks still wait for their source and destination volumes."
                    )
                }
            }
            card {
                Toggle(isOn: $automaticCameraDetection) {
                    heading(
                        "Automatically detect Camera/Card for new transfers",
                        "Default off. When enabled, mounted camera-style volumes open a review suggestion; nothing is queued or started automatically."
                    )
                }
            }
        }
    }

    private var verificationSettings: some View {
        Group {
            card {
                HStack {
                    heading(
                        "Checksum",
                        "A new task snapshots this global choice. It is not changed in New Offload."
                    )
                    Spacer()
                    Picker("Checksum", selection: $checksum) {
                        ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                            Text(algorithm.displayName).tag(algorithm)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 12) {
                    heading("Default verification profile", verificationProfile.detail)
                    Picker("Verification profile", selection: $verificationProfile) {
                        ForEach(VerificationProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    Text("Fast ends yellow and does not permit verified eject. Standard is the recommended default. Maximum independently pre-reads the source before copying.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var profileSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                HStack(spacing: 10) {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(createProfile)
                    Button("Add Profile", action: createProfile)
                        .buttonStyle(.glassProminent)
                        .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local profiles").font(.headline)
                        ForEach(model.productStore.profiles) { profile in
                            Button {
                                select(profile)
                            } label: {
                                HStack(spacing: 10) {
                                    OperatorAvatarView(
                                        profile: profile,
                                        avatarStore: model.productStore.avatars,
                                        size: 34
                                    )
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(profile.displayName)
                                        if profile.id == model.productStore.activeProfile.id {
                                            Text("Active operator")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Spacer()
                                    if profile.id == selectedProfileID {
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(7)
                                .background(
                                    profile.id == selectedProfileID ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 300)

                if let profile = selectedProfile {
                    profileEditor(profile)
                }
            }
        }
    }

    private var workflowSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    heading(
                        "Destination Library",
                        "Save logical destinations with explicit roles. Paths are revalidated every time a preset is used."
                    )
                    Picker("Role for added destinations", selection: $destinationRole) {
                        ForEach(DestinationRole.allCases) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    .frame(width: 180)
                    ForEach(model.recentDestinations, id: \.self) { url in
                        let saved = model.workflowLibrary.destinations.contains {
                            $0.path == url.standardizedFileURL.path
                        }
                        HStack {
                            Image(systemName: "externaldrive")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                Text(url.path).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(saved ? "Saved" : "Add") {
                                model.workflowLibrary.addDestination(url: url, role: destinationRole)
                            }
                            .buttonStyle(.glass)
                            .disabled(saved)
                        }
                    }
                    if model.recentDestinations.isEmpty {
                        Text("Use a destination in an offload first, then add it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.workflowLibrary.destinations) { destination in
                        HStack {
                            Text(destination.name).font(.callout.weight(.semibold))
                            Text(destination.role.displayName)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            Text(destination.path).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                model.workflowLibrary.removeDestination(destination)
                            } label: { Image(systemName: "xmark") }
                            .buttonStyle(.glass)
                        }
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Destination Groups", "A named set fans out directly from the source; destinations never chain implicitly.")
                    HStack {
                        TextField("Group name", text: $groupName)
                            .textFieldStyle(.roundedBorder)
                        Button("Create from all saved destinations") {
                            model.workflowLibrary.addGroup(
                                name: groupName,
                                destinationIDs: model.workflowLibrary.destinations.map(\.id)
                            )
                            groupName = ""
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.workflowLibrary.destinations.isEmpty)
                    }
                    ForEach(model.workflowLibrary.groups) { group in
                        Text("\(group.name) · \(group.destinationIDs.count) destinations")
                            .font(.callout)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Folder naming templates", "Tokens: {date}, {project}, {day}, {camera}, {card}, {source}, {operator}, {counter}.")
                    HStack {
                        TextField("Template name", text: $templateName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        TextField("Pattern", text: $templatePattern)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            model.workflowLibrary.addTemplate(name: templateName, pattern: templatePattern)
                            templateName = ""
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(templateName.isEmpty || !NamingTemplateRenderer.validate(templatePattern))
                    }
                    ForEach(model.workflowLibrary.templates) { template in
                        Text("\(template.name) · \(template.pattern)")
                            .font(.callout)
                    }
                }
            }

            card {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Versioned presets", "Bundle verification, a destination group, and a naming template for one-click review setup.")
                    HStack {
                        TextField("Preset name", text: $presetName)
                            .textFieldStyle(.roundedBorder)
                        Picker("Verification", selection: $presetVerification) {
                            ForEach(VerificationProfile.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Group", selection: $presetGroupID) {
                            Text("No group").tag(nil as UUID?)
                            ForEach(model.workflowLibrary.groups) { Text($0.name).tag($0.id as UUID?) }
                        }
                        Picker("Naming", selection: $presetTemplateID) {
                            Text("Manual name").tag(nil as UUID?)
                            ForEach(model.workflowLibrary.templates) { Text($0.name).tag($0.id as UUID?) }
                        }
                        Button("Add Preset") {
                            model.workflowLibrary.addPreset(
                                name: presetName,
                                verificationProfile: presetVerification,
                                groupID: presetGroupID,
                                templateID: presetTemplateID
                            )
                            presetName = ""
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ForEach(model.workflowLibrary.presets) { preset in
                        Text("\(preset.name) v\(preset.version) · \(preset.verificationProfile.displayName)")
                            .font(.callout)
                    }
                }
            }
        }
    }

    private func profileEditor(_ profile: OperatorProfile) -> some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    OperatorAvatarView(
                        profile: profile,
                        avatarStore: model.productStore.avatars,
                        size: 72
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        model.productStore.importAvatar(from: url, for: profile)
                        return true
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Avatar").font(.headline)
                        HStack {
                            Button("Choose Image…") { importingAvatar = true }
                                .buttonStyle(.glass)
                            Button("Use Initials") {
                                model.productStore.useInitialsAvatar(for: profile, colorHex: editedColor)
                            }
                            .buttonStyle(.glass)
                        }
                        Text("Drop an image onto the avatar, or use local initials and color.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("Display name", text: $editedProfileName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Avatar color (hex)", text: $editedColor)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Spacer()
                    Button("Make Active") { model.productStore.activate(profile) }
                        .buttonStyle(.glass)
                        .disabled(profile.id == model.productStore.activeProfile.id)
                    Button("Save") {
                        model.productStore.updateProfile(
                            profile,
                            displayName: editedProfileName,
                            colorHex: editedColor
                        )
                    }
                    .buttonStyle(.glassProminent)
                    Button("Archive", role: .destructive) {
                        model.productStore.archive(profile)
                        selectedProfileID = model.productStore.activeProfile.id
                    }
                    .disabled(model.productStore.profiles.count <= 1)
                }
                Text("Profiles are local attribution, not authenticated accounts. Historical attempts keep the name that was selected when they were created.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reportSettings: some View {
        card {
            Toggle(isOn: $automaticContactSheet) {
                heading(
                    "Generate a contact sheet after verified transfers",
                    "Default off. A contact-sheet warning never changes a verified media result."
                )
            }
        }
    }

    private var dataSettings: some View {
        Group {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    heading(
                        "Settings package",
                        "Export or merge global settings and local profiles, including avatar assets. Transfer history and evidence are never included."
                    )
                    HStack {
                        Button(action: exportSettings) {
                            Label("Export Settings…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        Button(action: importSettings) {
                            Label("Import Settings…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.glass)
                        Spacer()
                    }
                    if let settingsMessage {
                        Text(settingsMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            card {
                HStack(spacing: 12) {
                    heading("Spool folder", "Portable manifests, reports, MHL, journals, and logs.")
                    Spacer()
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([TransferSession.spoolDirectory])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                }
            }
            card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Doppelganger")
                    Text("Checksums: XXH3-64, XXH64BE, MD5 · manifest schema v\(TransferManifest.currentSchemaVersion) · ASC MHL v2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func createProfile() {
        model.productStore.createProfile(displayName: newProfileName)
        newProfileName = ""
        select(model.productStore.activeProfile)
    }

    private func select(_ profile: OperatorProfile) {
        selectedProfileID = profile.id
        editedProfileName = profile.displayName
        editedColor = profile.avatar.colorHex
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Doppelganger Settings.\(SettingsPackageService.fileExtension)"
        panel.allowedContentTypes = [
            UTType(filenameExtension: SettingsPackageService.fileExtension) ?? .json
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsPackageService.export(
                to: url,
                store: model.productStore,
                workflowLibrary: model.workflowLibrary
            )
            settingsMessage = L10n.format("Settings exported to %@.", url.lastPathComponent)
        } catch {
            settingsMessage = L10n.format("Export failed: %@", error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: SettingsPackageService.fileExtension) ?? .json,
            .json
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsPackageService.importPackage(
                from: url,
                store: model.productStore,
                workflowLibrary: model.workflowLibrary
            )
            select(model.productStore.activeProfile)
            settingsMessage = L10n.text("Settings imported and merged.")
        } catch {
            settingsMessage = L10n.format("Import failed: %@", error.localizedDescription)
        }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(title))
            Text(LocalizedStringKey(subtitle))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }
}
