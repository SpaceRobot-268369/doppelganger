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

    private var header: some View {
        HStack {
            Text(model.activeCount > 0 ? "Active transfers" : "Transfers")
                .font(.largeTitle.weight(.bold))
            Spacer()
            Button {
                model.beginOffload()
            } label: {
                Label("New Offload", systemImage: "plus")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    /// One click from card-in-reader to running transfer — but never zero:
    /// offloading always takes an explicit action.
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
                model.draftSource = volume.url
                model.mountBanner = nil
                if model.canStartDraft {
                    model.startDraftOffload(autoShowLog: autoShowLog)
                } else {
                    model.beginOffload(source: volume.url)
                }
            } label: {
                Label("Offload Now", systemImage: "play.fill")
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
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                chip(.all, count: model.sessions.count, dot: nil)
                chip(.active, count: model.activeCount, dot: .green)
                chip(.complete, count: model.completeCount, dot: .secondary)
                Spacer()
            }
        }
    }

    private func chip(_ filter: TransferFilter, count: Int, dot: Color?) -> some View {
        Button {
            model.filter = filter
        } label: {
            HStack(spacing: 7) {
                if let dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(filter.title)
                    .font(.callout.weight(model.filter == filter ? .semibold : .regular))
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .glassEffect(
            model.filter == filter ? .regular.tint(.blue.opacity(0.4)) : .regular,
            in: .capsule
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.secondary)
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
