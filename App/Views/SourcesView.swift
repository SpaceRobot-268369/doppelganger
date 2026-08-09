import AppKit
import SwiftUI

/// Recently offloaded sources, with a quick path back into a new offload,
/// plus everything currently mounted that could be a source.
struct SourcesView: View {
    @Bindable var model: AppModel

    var body: some View {
        RecentsListView(
            title: "Sources",
            emptyText: "Sources you offload will appear here.",
            icon: "sdcard",
            urls: model.recentSources,
            primaryAction: ("Offload…", { model.beginOffload(source: $0) }),
            onRemove: { model.removeRecentSource($0) },
            topSection: { mountedSection }
        )
        .onAppear { model.volumeWatcher.refresh() }
    }

    @ViewBuilder
    private var mountedSection: some View {
        if !model.volumeWatcher.volumes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Mounted volumes")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                ForEach(model.volumeWatcher.volumes) { volume in
                    HStack(spacing: 12) {
                        Image(systemName: volume.looksLikeCameraCard ? "sdcard.fill" : "externaldrive.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volume.name)
                                .font(.callout.weight(.semibold))
                            Text(volume.looksLikeCameraCard ? "Camera card structure detected" : volume.url.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Offload…") {
                            model.beginOffload(source: volume.url)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([volume.url])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.glass)
                        .help("Reveal in Finder")
                    }
                    .padding(14)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                }
                Text("Recent")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

/// Recently used destinations.
struct DestinationsView: View {
    @Bindable var model: AppModel

    var body: some View {
        RecentsListView(
            title: "Destinations",
            emptyText: "Destinations you copy to will appear here.",
            icon: "externaldrive",
            urls: model.recentDestinations,
            primaryAction: nil,
            onRemove: { model.removeRecentDestination($0) },
            topSection: { EmptyView() }
        )
    }
}

private struct RecentsListView<TopSection: View>: View {
    let title: String
    let emptyText: String
    let icon: String
    let urls: [URL]
    let primaryAction: (label: String, run: (URL) -> Void)?
    let onRemove: (URL) -> Void
    @ViewBuilder let topSection: () -> TopSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal, 24)
                .padding(.top, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    topSection()
                    if urls.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: icon)
                                .font(.system(size: 40, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(emptyText)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        ForEach(urls, id: \.self) { url in
                            row(url)
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ url: URL) -> some View {
        let mounted = FileManager.default.fileExists(atPath: url.path)
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(mounted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.callout.weight(.semibold))
                Text(Format.middleTruncated(url.path, max: 72))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !mounted {
                Text("Not mounted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let primaryAction, mounted {
                Button(primaryAction.label) { primaryAction.run(url) }
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.glass)
            .disabled(!mounted)
            .help("Reveal in Finder")
            Button {
                onRemove(url)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help("Remove from this list")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
