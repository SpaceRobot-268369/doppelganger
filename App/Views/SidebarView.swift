import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: sectionSelection) {
            Section {
                ForEach(SidebarSection.allCases.filter { $0 != .preferences }) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(section == .transfers && !model.sessions.isEmpty
                            ? model.activeCount + model.attentionCount : 0)
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

    /// Compact status pinned beneath the native sidebar rows.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider()
                .padding(.bottom, 6)
            HStack(spacing: 7) {
                Image(systemName: model.systemNominal ? "circle.fill" : "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(
                        model.systemNominal ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                    )
                Text(model.systemNominal ? "No current issues" : "Attention needed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .help(model.systemNominal ? "No current transfer has reported a problem" : "A transfer did not verify")
            SidebarFooterRow(
                title: SidebarSection.preferences.title,
                icon: SidebarSection.preferences.icon,
                selected: model.section == .preferences
            ) {
                model.section = .preferences
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 10)
    }
}

private struct SidebarFooterRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.22) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}
