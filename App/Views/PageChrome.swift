import SwiftUI

/// The circular Liquid Glass back control every secondary page uses. One shape
/// and one position, so leaving a detail page is the same gesture everywhere.
struct BackButton: View {
    let label: LocalizedStringKey
    let action: () -> Void
    var size: CGFloat = 38

    init(_ label: LocalizedStringKey = "Back", size: CGFloat = 38, action: @escaping () -> Void) {
        self.label = label
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: size * 0.36, weight: .semibold))
                // The glyph sits a hair left of centre optically; nudge it back
                // so it reads centred inside the circle.
                .offset(x: -0.5)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        // The glass renders as a circle rather than being clipped to one, which
        // is what cut the material's edge highlight off mid-stroke.
        .buttonBorderShape(.circle)
        .help(label)
        .accessibilityLabel(label)
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// Secondary pages replace the section in place rather than sliding or fading.
/// Navigating a working page should feel instantaneous, not animated.
func withoutPageAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

/// Title block shared by secondary pages: back control, title, subtitle, and
/// whatever trailing controls the page owns.
struct SecondaryPageHeader<Trailing: View>: View {
    let backLabel: LocalizedStringKey
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let onBack: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            BackButton(backLabel, action: onBack)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}

extension SecondaryPageHeader where Trailing == EmptyView {
    init(
        backLabel: LocalizedStringKey,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        onBack: @escaping () -> Void
    ) {
        self.init(
            backLabel: backLabel,
            title: title,
            subtitle: subtitle,
            onBack: onBack,
            trailing: { EmptyView() }
        )
    }
}
