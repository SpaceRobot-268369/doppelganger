import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                            NSWorkspace.shared.open(volume.url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.glass)
                        .help("Open in Finder")
                    }
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
                }
                Text("Recent")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
    }
}

private enum DestinationPageScope: String, CaseIterable, Identifiable {
    case all = "All"
    case library = "Library"
    case recent = "Recent"

    var id: String { rawValue }
}

private struct DestinationPageItem: Identifiable {
    let url: URL
    let saved: LogicalDestination?

    var id: String { url.standardizedFileURL.path }
}

/// Stable destination identities plus recent paths and verified use history.
struct DestinationsView: View {
    @Bindable var model: AppModel
    @State private var scope = DestinationPageScope.all
    @State private var addRole = DestinationRole.backup
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Destinations")
                        .font(.largeTitle.weight(.bold))
                    Text("Stable storage identities, roles, capacity, benchmarks, and verified use history.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("New destination role", selection: $addRole) {
                    ForEach(DestinationRole.allCases) { role in
                            Text(role.displayName).tag(role)
                    }
                }
                .frame(width: 140)
                Button("Add Destination…", action: chooseDestination)
                    .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(DestinationPageScope.allCases) { value in
                        SubtabFilterChip(value.rawValue, isSelected: scope == value) {
                            scope = value
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
            }
            .scrollIndicators(.hidden)

            if pageItems.isEmpty {
                ContentUnavailableView {
                    Label("No destinations yet", systemImage: "externaldrive")
                } description: {
                    Text("Add a folder, drop one here, or use it in an offload first.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(pageItems) { item in
                            destinationRow(item)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self, action: { urls, _ in
            let directories = urls.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            for url in directories {
                model.workflowLibrary.addDestination(url: url, role: addRole)
            }
            return !directories.isEmpty
        }, isTargeted: { isDropTargeted = $0 })
        .onAppear {
            for destination in model.workflowLibrary.destinations {
                model.workflowLibrary.refreshDestination(destination)
            }
        }
    }

    private var pageItems: [DestinationPageItem] {
        let saved = model.workflowLibrary.destinations.map {
            DestinationPageItem(url: URL(fileURLWithPath: $0.path), saved: $0)
        }
        let savedPaths = Set(saved.map(\.id))
        let recent = model.recentDestinations.compactMap { url -> DestinationPageItem? in
            guard !savedPaths.contains(url.standardizedFileURL.path) else { return nil }
            return DestinationPageItem(url: url, saved: nil)
        }
        return switch scope {
        case .all: saved + recent
        case .library: saved
        case .recent: recent
        }
    }

    private func destinationRow(_ item: DestinationPageItem) -> some View {
        let destination = item.url
        let mounted = FileManager.default.fileExists(atPath: destination.path)
        let result = model.benchmarkResult(for: destination)
        let benchmarking = model.isBenchmarking(destination)
        let liveVolume = mounted ? try? RealFileSystem().volume(at: destination) : nil
        let verifiedTasks = model.productStore.taskHistory.filter {
            $0.verdict == .verified && $0.destinationPaths.contains(destination.standardizedFileURL.path)
        }
        let identityMismatch = if let savedID = item.saved?.volumeIdentifier,
                                  let liveID = liveVolume?.identifier {
            savedID != liveID
        } else { false }

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(identityMismatch ? AnyShapeStyle(.red) : mounted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.saved?.name ?? destination.lastPathComponent)
                        .font(.callout.weight(.semibold))
                    if let saved = item.saved {
                        Menu {
                            ForEach(DestinationRole.allCases) { role in
                                Button(role.displayName) {
                                    model.workflowLibrary.updateRole(saved, role: role)
                                }
                            }
                        } label: {
                            Text(saved.role.displayName)
                                .font(.caption.weight(.semibold))
                        }
                        .menuStyle(.button)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .fixedSize()
                    } else {
                        Text("Recent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(Format.middleTruncated(destination.path, max: 72))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if identityMismatch {
                    Label("A different volume is mounted at this saved path", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else if let volume = liveVolume ?? observedVolume(item.saved) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let available = volume.availableBytes, let total = volume.totalBytes, total > 0 {
                            ProgressView(value: Double(total - available), total: Double(total))
                                .frame(maxWidth: 360)
                            Text("\(bytes(available)) available of \(bytes(total))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(volume.name) · ID \(Format.middleTruncated(volume.identifier, max: 38))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let result {
                    Text("Write \(Format.rate(result.writeBytesPerSecond)) · Read \(Format.rate(result.readBytesPerSecond)) · \(result.measuredAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !verifiedTasks.isEmpty {
                    let latest = verifiedTasks.map(\.updatedAt).max() ?? Date()
                    Text("\(verifiedTasks.count) verified transfer\(verifiedTasks.count == 1 ? "" : "s") · last \(latest.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
            if !mounted {
                Text("Not mounted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if item.saved == nil {
                Button("Save") {
                    model.workflowLibrary.addDestination(url: destination, role: addRole)
                }
                .buttonStyle(.glassProminent)
                .disabled(!mounted)
            }
            Button {
                model.benchmarkDestination(destination)
            } label: {
                Label(benchmarking ? "Testing…" : "Benchmark", systemImage: "speedometer")
            }
            .buttonStyle(.glass)
            .disabled(!mounted || benchmarking)
            .help("Write and read a disposable 32 MB test file; source media is never touched")
            Button {
                NSWorkspace.shared.open(destination)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.glass)
            .disabled(!mounted)
            if let saved = item.saved {
                Menu {
                    Button("Refresh Capacity and Identity") {
                        model.workflowLibrary.refreshDestination(saved)
                    }
                    Button("Remove from Library", role: .destructive) {
                        model.workflowLibrary.removeDestination(saved)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.glass)
            } else {
                Button {
                    model.removeRecentDestination(destination)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }

    private func observedVolume(_ destination: LogicalDestination?) -> FileSystemVolume? {
        guard let destination,
              let identifier = destination.volumeIdentifier,
              let name = destination.volumeName
        else { return nil }
        return FileSystemVolume(
            identifier: identifier,
            name: name,
            mountPath: destination.path,
            availableBytes: destination.lastAvailableBytes,
            totalBytes: destination.totalBytes
        )
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.workflowLibrary.addDestination(url: url, role: addRole)
        }
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
            Text(LocalizedStringKey(title))
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
                            Text(LocalizedStringKey(emptyText))
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
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.glass)
            .disabled(!mounted)
            .help("Open in Finder")
            Button {
                onRemove(url)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .help("Remove from this list")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }
}
