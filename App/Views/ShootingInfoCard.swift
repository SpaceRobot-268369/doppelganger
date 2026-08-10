import SwiftUI

/// What was shot, in the crew's own vocabulary: shooting day, camera, and reel.
/// These are catalog labels — they never reorganize source media — but the reel
/// is also what names the transfer folder, so the section sits with the plan
/// rather than behind a disclosure.
struct ShootingInfoCard: View {
    @Bindable var model: AppModel
    @Binding var selectedPresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Shooting Info", systemImage: "camera.badge.clock")
                    .font(.headline)
                Spacer()
                if !model.workflowLibrary.presets.isEmpty {
                    Text("Preset")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Preset", selection: $selectedPresetID) {
                        Text("Custom").tag(nil as UUID?)
                        ForEach(model.workflowLibrary.presets) { preset in
                            Text("\(preset.name) v\(preset.version)").tag(preset.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                if !model.draftCameraOptions.isEmpty {
                    field("Project Camera", width: 190) {
                        Picker(
                            "Project Camera",
                            selection: Binding(
                                get: { model.draftCamera?.id },
                                set: { id in
                                    model.selectDraftCamera(
                                        model.draftCameraOptions.first { $0.id == id }
                                    )
                                }
                            )
                        ) {
                            Text("Unassigned").tag(nil as UUID?)
                            ForEach(model.draftCameraOptions) { camera in
                                Text("\(camera.reelPrefix) · \(camera.displayName)").tag(camera.id as UUID?)
                            }
                        }
                        .labelsHidden()
                        .help("Fills the camera and reel below with this project's next reel.")
                    }
                }
                field("Shooting Day") {
                    TextField("Day 01", text: $model.draftShootingDay)
                }
                field("Camera") {
                    TextField("A Camera", text: $model.draftCameraLabel)
                }
                field("Reel Name") {
                    TextField(reelPlaceholder, text: $model.draftCardLabel)
                }
            }

            Text("Catalog labels for history and search; they never reorganize source media. The reel name is what the transfer folder is named after.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }

    /// An empty reel falls back to the convention-shaped default the source
    /// implies, so the placeholder shows what will actually be used.
    private var reelPlaceholder: String {
        guard let source = model.draftSource else { return "A001" }
        return TransferPreflight.reelName(for: source)
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey,
        width: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator.opacity(0.4)))
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}
