import AppKit
import SwiftUI

struct TransfersView: View {
    @Bindable var model: AppModel
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
            if let banner = model.mountBanner {
                mountBanner(banner)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            filterChips
                .padding(.horizontal, 24)
                .padding(.top, 14)
            if model.filteredSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(model.filteredSessions.enumerated()), id: \.element.id) { index, session in
                            TransferCardView(model: model, session: session, index: index + 1)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .animation(.snappy, value: model.filteredSessions.map(\.id))
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Starting a transfer must be reachable at any time, not only from the
    /// empty state — the dashboard is busiest exactly when the next card
    /// arrives.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.activeCount > 0 ? "Active transfers" : "Transfers")
                .font(.largeTitle.weight(.bold))
            Spacer()
            Button {
                model.beginOffload()
            } label: {
                Label("New Offload", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            // ⌘N lives on the File menu command so it works on every page.
            .help("Review and start a new offload")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Card detection removes selection friction, but still opens the review
    /// sheet: exact output paths and preflight findings are never bypassed.
    private func mountBanner(_ volume: MountedVolume) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(volume.name) mounted")
                    .font(.callout.weight(.semibold))
                Text("Offload to your last destinations?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.mountBanner = nil
                model.beginOffload(source: volume.url)
            } label: {
                Label("Review Offload", systemImage: "checklist")
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            Button("Choose…") {
                model.mountBanner = nil
                model.beginOffload(source: volume.url)
            }
            .buttonStyle(.glass)
            Button {
                model.mountBanner = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular.tint(.blue.opacity(0.25)), in: .rect(cornerRadius: 14))
    }

    private var filterChips: some View {
        HStack(spacing: 10) {
            chip(.all, count: model.sessions.count)
            chip(.active, count: model.activeCount, dot: .blue)
            chip(.attention, count: model.attentionCount, dot: .red)
            chip(.verified, count: model.verifiedCount, dot: .green)
            Spacer()
        }
    }

    private func chip(_ filter: TransferFilter, count: Int, dot: Color? = nil) -> some View {
        SubtabFilterChip(
            filter.title,
            count: count,
            dot: dot,
            isSelected: model.filter == filter
        ) {
            model.filter = filter
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            // The mascot, not a generic symbol — the ghost is the brand.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            Text(model.sessions.isEmpty ? "No transfers yet" : "Nothing matches this filter")
                .font(.title3.weight(.semibold))
            Text("Copy. Verify every byte. Prove it.")
                .foregroundStyle(.secondary)
            if model.sessions.isEmpty {
                Button {
                    model.beginOffload()
                } label: {
                    Label("New Offload", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(model.sessions.count) transfer\(model.sessions.count == 1 ? "" : "s")")
            Spacer()
            if model.totalPlannedBytes > 0 {
                Text("Total: \(Format.bytes(model.totalPlannedBytes))")
            }
            if model.aggregateThroughput > 0 {
                Text(Format.rate(model.aggregateThroughput))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.quinary)
    }
}
