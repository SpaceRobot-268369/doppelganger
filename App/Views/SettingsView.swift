import AppKit
import SwiftUI

/// The app's Settings scene content (⌘,). Values live in UserDefaults so the
/// dashboard's AppModel can read them without sharing state across scenes.
struct SettingsView: View {
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false
    @AppStorage(AppModel.maxConcurrentKey) private var maxConcurrent = AppModel.defaultMaxConcurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Stepper(value: $maxConcurrent, in: 1...4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Simultaneous transfers: \(maxConcurrent)")
                    Text("Extra offloads wait in the queue and start automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            Toggle(isOn: $autoShowLog) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open the log panel automatically")
                    Text("New transfers start with their live log expanded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spool folder")
                    Text("Manifests, reports, and logs for every transfer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TransferSession.spoolDirectory])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.glass)
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            HStack {
                Text("Doppelganger")
                Text("· checksums: XXH64, MD5 · manifest schema v\(TransferManifest.currentSchemaVersion) · MHL v1.1")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(22)
        .frame(width: 460)
    }
}
