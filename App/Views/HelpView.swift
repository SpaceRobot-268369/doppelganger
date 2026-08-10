import SwiftUI

private enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted = "Getting Started"
    case statuses = "Status & Safety"
    case evidence = "Evidence"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }
}

struct HelpView: View {
    @State private var topic = HelpTopic.gettingStarted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Help")
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal, 24)
                .padding(.top, 20)
            HStack(spacing: 10) {
                ForEach(HelpTopic.allCases) { item in
                    SubtabFilterChip(item.rawValue, isSelected: topic == item) {
                        topic = item
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch topic {
                    case .gettingStarted:
                        article(
                            "A safe offload",
                            "Choose or drop a source, add one or more destinations, review the exact output folders, run Preflight, then start. A Finder drop only fills the review—it never starts work."
                        )
                        article(
                            "Projects and operators",
                            "Projects are optional. The active Operator Profile shown in the sidebar is recorded when a task and attempt are created; it is local attribution, not a login."
                        )
                    case .statuses:
                        article("Blue — Copying", "Data is still moving. Keep every device connected.")
                        article("Cyan — Verifying", "Destination files are being read back independently.")
                        article("Yellow — Verification pending", "Fast mode finished copying but has not completed destination read-back. Keep the source and do not eject it as verified.")
                        article("Green — Verified", "Every required destination copy and core evidence artifact passed.")
                        article("Red — Failed", "At least one required copy, verification, or evidence artifact failed. Keep the source media.")
                    case .evidence:
                        article("JSON manifest", "The complete machine-readable task and per-file result, including checksum, operator snapshot, destinations, and issues.")
                        article("ASC MHL", "The interoperable hash list used for later verification and chain-of-custody workflows.")
                        article("Contact sheet", "An optional visual artifact. A contact-sheet failure never changes successfully verified media into a failed transfer.")
                    case .troubleshooting:
                        article("A volume disappeared", "Reconnect it, keep the source, and review the failed attempt. Retry or resume creates new evidence; it never edits the old result.")
                        article("Permission denied", "Re-select the folder and check System Settings → Privacy & Security → Files and Folders or Full Disk Access when the location requires it.")
                        article("Existing output", "doppelganger never overwrites it. Choose a new task-folder name or verify the existing copy separately.")
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func article(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(body))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }
}
