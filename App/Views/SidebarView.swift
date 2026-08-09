import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: sectionSelection) {
            Section {
                ForEach(SidebarSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(section == .transfers && !model.sessions.isEmpty
                            ? model.sessions.count : 0)
                        .tag(section)
                }
            } header: {
                header
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private var sectionSelection: Binding<SidebarSection?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } }
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: .rect(cornerRadius: 9))
            Text("Doppelganger")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 10)
        .textCase(nil)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: model.systemNominal ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .foregroundStyle(model.systemNominal ? .green : .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.systemNominal ? "System OK" : "Attention needed")
                        .font(.callout.weight(.semibold))
                    Text(model.systemNominal
                        ? "All systems nominal"
                        : "A transfer did not verify")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            SettingsLink {
                Label("Preferences", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
        }
        .padding(12)
    }
}
