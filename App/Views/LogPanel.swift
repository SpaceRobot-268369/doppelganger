import SwiftUI

/// Live, auto-scrolling transfer log. Monospaced, level-tinted, selectable.
struct LogPanel: View {
    let entries: [TransferLogEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(entries) { entry in
                        Text(entry.formattedLine)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(for: entry.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(10)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: entries.count) {
                if let last = entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func color(for level: TransferLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
