import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: sectionSelection) {
            Section {
                // Settings lives in the footer; Compare is not yet a shipped
                // feature and stays out of the top-level list until it is.
                ForEach(SidebarSection.allCases.filter { $0 != .preferences && $0 != .compare }) { section in
                    Label(section.title, systemImage: section.icon)
                        .badge(section == .transfers ? transfersBadgeCount : 0)
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

    /// Every session that is still working or needs attention, counted once
    /// even when a running transfer already has a live failure.
    private var transfersBadgeCount: Int {
        model.sessions.filter { $0.isActive || $0.needsAttention }.count
    }

    /// While a secondary page is open the sidebar shows no selection, so any
    /// row — including the section the page opened over — is a change the list
    /// reports back and the page steps aside for.
    private var sectionSelection: Binding<SidebarSection?> {
        Binding(
            get: { model.showingNewOffload ? nil : model.section },
            set: { if let section = $0 { model.selectSection(section) } }
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
            Menu {
                ForEach(model.productStore.profiles) { profile in
                    Button {
                        model.productStore.activate(profile)
                    } label: {
                        if profile.id == model.productStore.activeProfile.id {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                }
                Divider()
                Button("Manage Profiles…") {
                    model.selectSection(.preferences)
                }
            } label: {
                HStack(spacing: 9) {
                    OperatorAvatarView(
                        profile: model.productStore.activeProfile,
                        avatarStore: model.productStore.avatars,
                        size: 30
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.productStore.activeProfile.displayName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text("Active operator")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .help("Switch the local operator recorded in new tasks and audit events")
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
            .help(model.systemNominal
                ? "No current transfer has reported a problem"
                : "A transfer failed, was cancelled, or still needs verification")
            SidebarFooterRow(
                title: SidebarSection.preferences.title,
                icon: SidebarSection.preferences.icon,
                selected: model.section == .preferences && !model.showingNewOffload
            ) {
                model.selectSection(.preferences)
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
