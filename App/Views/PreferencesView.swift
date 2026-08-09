import AppKit
import SwiftUI

/// Dedicated in-app Preferences tab selected from the sidebar or with ⌘,.
struct PreferencesView: View {
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false
    @AppStorage(AppModel.maxConcurrentKey) private var maxConcurrent = AppModel.defaultMaxConcurrent
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preferences")
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal, 24)
                .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    appearanceCard
                    concurrencyCard
                    logCard
                    spoolCard
                    about
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(appearance.colorScheme)
    }

    private var appearanceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                heading("Appearance", "Follows the system unless you pick a side.")
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Label(option.title, systemImage: option.icon).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
        }
    }

    private var concurrencyCard: some View {
        card {
            Stepper(value: $maxConcurrent, in: 1...4) {
                heading(
                    "Simultaneous transfers: \(maxConcurrent)",
                    "Extra offloads wait in the queue and start automatically."
                )
            }
        }
    }

    private var logCard: some View {
        card {
            Toggle(isOn: $autoShowLog) {
                heading(
                    "Open the log panel automatically",
                    "New transfers start with their live log expanded."
                )
            }
        }
    }

    private var spoolCard: some View {
        card {
            HStack(spacing: 12) {
                heading("Spool folder", "Manifests, reports, and logs for every transfer.")
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TransferSession.spoolDirectory])
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var about: some View {
        HStack {
            Text("Doppelganger")
            Text("· checksums: XXH64, MD5 · manifest schema v\(TransferManifest.currentSchemaVersion) · MHL v1.1")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 4)
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
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
