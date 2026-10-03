import AppKit
import SwiftUI

/// Overlays a progress bar on the Dock icon while transfers run, plus a badge
/// with the active-transfer count.
@MainActor
final class DockProgressController {
    private var hosting: NSHostingView<DockIconView>?

    /// `fraction == nil` restores the plain icon.
    func update(fraction: Double?, activeCount: Int) {
        let tile = NSApp.dockTile
        tile.badgeLabel = activeCount > 0 ? "\(activeCount)" : nil
        if let fraction {
            let view = DockIconView(fraction: fraction)
            if let hosting {
                hosting.rootView = view
            } else {
                let fresh = NSHostingView(rootView: view)
                fresh.frame = NSRect(x: 0, y: 0, width: 128, height: 128)
                tile.contentView = fresh
                hosting = fresh
            }
        } else {
            hosting = nil
            tile.contentView = nil
        }
        tile.display()
    }
}

private struct DockIconView: View {
    let fraction: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
            Capsule()
                .fill(.black.opacity(0.55))
                .frame(height: 13)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        // Blue is "copying"; green is reserved for verified.
                        Capsule()
                            .fill(.blue)
                            .frame(width: max(geometry.size.width * fraction, 12))
                    }
                    .padding(2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }
    }
}
