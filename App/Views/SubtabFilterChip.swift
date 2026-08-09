import SwiftUI

/// The shared visual language for peer filters inside a page. Keeping this in
/// one component prevents dense filter bars from drifting back toward a
/// segmented control or developing inconsistent hit targets.
struct SubtabFilterChip: View {
    let title: String
    let count: Int?
    let dot: Color?
    let isSelected: Bool
    let action: () -> Void

    init(
        _ title: String,
        count: Int? = nil,
        dot: Color? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.count = count
        self.dot = dot
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: count)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .glassEffect(
                isSelected ? .regular.tint(.blue.opacity(0.4)) : .regular,
                in: .capsule
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
