import AppKit
import SwiftUI

struct OperatorAvatarView: View {
    let profile: OperatorProfile
    let avatarStore: AvatarStore
    var size: CGFloat = 28

    var body: some View {
        Group {
            if profile.avatar.kind == .image,
               let url = avatarStore.url(for: profile.avatar.imageFileName),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(hex: profile.avatar.colorHex) ?? .blue
                    Text(profile.initials)
                        .font(.system(size: max(size * 0.34, 9), weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
        .accessibilityLabel("Operator \(profile.displayName)")
    }
}

private extension Color {
    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255
        )
    }
}
