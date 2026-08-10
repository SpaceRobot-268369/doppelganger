import AppKit
import SwiftUI

private enum DiskCollectionScope: String, CaseIterable, Identifiable {
    case all = "All"
    case internalStorage = "Internal Storage"
    case externalDisks = "External Disks"
    case cameraCards = "Camera Cards"

    var id: String { rawValue }
}

struct ConnectedDisksView: View {
    @Bindable var model: AppModel
    @State private var scope = DiskCollectionScope.all
    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            GeometryReader { proxy in
                HStack(alignment: .top, spacing: 18) {
                    master
                        .frame(minWidth: 360, idealWidth: 520, maxWidth: .infinity)
                    ScrollView(.vertical) {
                        inspector
                            .padding(.bottom, 1)
                    }
                    .scrollIndicators(.visible)
                    .frame(width: min(480, max(380, proxy.size.width * 0.42)))
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            model.volumeWatcher.refresh()
            selectFirstIfNeeded()
        }
        .onChange(of: model.volumeWatcher.volumes) { _, _ in selectFirstIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            title
            Spacer(minLength: 20)
            refreshButton
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Storage").font(.largeTitle.weight(.bold))
            Text("Inspect internal storage, external disks, and camera cards.").foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button {
            model.volumeWatcher.refresh()
            selectFirstIfNeeded()
        } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.glass).help("Refresh mounted disks")
    }

    private var master: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(DiskCollectionScope.allCases) { value in
                        SubtabFilterChip("\(value.rawValue)  \(count(for: value))", isSelected: scope == value) {
                            scope = value
                            if !filteredVolumes.contains(where: { $0.id == selectedID }) {
                                selectedID = filteredVolumes.first?.id
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if filteredVolumes.isEmpty {
                ContentUnavailableView {
                    Label("No matching disks", systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("No mounted disk matches this category.")
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredVolumes) { volume in diskRow(volume) }
                    }
                }
            }
            Text("\(filteredVolumes.count) mounted disk\(filteredVolumes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var inspector: some View {
        Group {
            if let volume = selectedVolume {
                DiskInspector(volume: volume)
            } else {
                ContentUnavailableView("Select a disk", systemImage: "externaldrive")
                    .frame(maxWidth: .infinity, minHeight: 440)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
    }

    private var filteredVolumes: [MountedVolume] {
        model.volumeWatcher.volumes.filter { volume in
            switch scope {
            case .all: true
            case .internalStorage: volume.storageCategory == .internalStorage
            case .externalDisks: volume.storageCategory == .externalDisk
            case .cameraCards: volume.looksLikeCameraCard
            }
        }
    }

    private var selectedVolume: MountedVolume? {
        filteredVolumes.first { $0.id == selectedID }
    }

    private func count(for value: DiskCollectionScope) -> Int {
        switch value {
        case .all: model.volumeWatcher.volumes.count
        case .internalStorage:
            model.volumeWatcher.volumes.filter { $0.storageCategory == .internalStorage }.count
        case .externalDisks:
            model.volumeWatcher.volumes.filter { $0.storageCategory == .externalDisk }.count
        case .cameraCards: model.volumeWatcher.volumes.filter(\.looksLikeCameraCard).count
        }
    }

    private func diskRow(_ volume: MountedVolume) -> some View {
        Button { selectedID = volume.id } label: {
            HStack(spacing: 14) {
                Image(systemName: diskSymbol(volume))
                    .font(.system(size: 32)).foregroundStyle(.tint).frame(width: 50)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(volume.name).font(.headline).lineLimit(1)
                        Text(diskKind(volume))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Text("\(volume.fileSystem)  ·  \(volume.connectionDescription)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    CapacityBar(volume: volume)
                    HStack {
                        Text(Format.middleTruncated(volume.url.path, max: 54))
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Text("\(bytes(volume.availableBytes)) available")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(15)
            .background(selectedID == volume.id ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(
                selectedID == volume.id ? Color.accentColor : Color.secondary.opacity(0.22), lineWidth: 1
            ))
            .contentShape(RoundedRectangle(cornerRadius: 15))
        }
        .buttonStyle(.plain)
    }

    private func selectFirstIfNeeded() {
        if selectedID == nil || !model.volumeWatcher.volumes.contains(where: { $0.id == selectedID }) {
            selectedID = model.volumeWatcher.volumes.first?.id
        }
    }

    private func diskKind(_ volume: MountedVolume) -> String {
        if volume.looksLikeCameraCard { return "Camera Card" }
        if volume.storageCategory == .internalStorage { return "Internal Storage" }
        return "External Disk"
    }

    private func diskSymbol(_ volume: MountedVolume) -> String {
        if volume.looksLikeCameraCard { return "sdcard.fill" }
        if volume.isInternal { return "internaldrive.fill" }
        return "externaldrive.fill"
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct DiskInspector: View {
    let volume: MountedVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: diskSymbol)
                    .font(.system(size: 36)).foregroundStyle(.tint).frame(width: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume.name).font(.title2.weight(.bold)).lineLimit(1)
                    Text(diskKind)
                        .font(.callout).foregroundStyle(.secondary)
                    Label("Mounted", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                }
                Spacer()
                Button { NSWorkspace.shared.open(volume.url) } label: { Image(systemName: "folder") }
                    .buttonStyle(.glass).help("Open in Finder")
            }

            inspectorSection {
                infoRow("Mount Point", volume.url.path)
                infoRow("File System", volume.fileSystem)
                infoRow("Volume ID", volume.volumeIdentifier ?? "Unavailable")
            }
            inspectorSection {
                HStack { Text("Capacity").font(.headline); Spacer(); Text("\(bytes(volume.totalBytes)) total").foregroundStyle(.secondary) }
                CapacityBar(volume: volume)
                HStack {
                    Label("\(bytes(volume.usedBytes)) used", systemImage: "circle.fill").foregroundStyle(.blue)
                    Spacer()
                    Label("\(bytes(volume.availableBytes)) available", systemImage: "circle.fill").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            inspectorSection {
                infoRow("Connection", volume.connectionDescription)
                infoRow("Removable", volume.isRemovable ? "Yes" : "No")
                infoRow("Read Only", volume.isReadOnly ? "Yes" : "No")
            }
            inspectorSection {
                Text("Basic Health Check").font(.headline)
                healthRow("Read access", passed: volume.isReadable, success: "Available")
                healthRow("Write access", passed: volume.isWritable, success: "Available",
                          failure: volume.isReadOnly ? "Read only" : "Unavailable")
                healthRow("Mounted filesystem", passed: volume.fileSystem != "Unknown", success: volume.fileSystem)
                healthRow("Free space", passed: volume.availableBytes > 0,
                          success: bytes(volume.availableBytes), failure: "No space reported")
                healthRow("Volume identity", passed: volume.volumeIdentifier != nil,
                          success: "Available", failure: "Unavailable")
                Text("This is an application-level capability check, not SMART, wear, or hardware-lifetime diagnostics.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            inspectorSection {
                HStack { Text("Speed Test").font(.headline); Spacer(); Text("Unavailable").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(speedExplanation).font(.caption).foregroundStyle(.secondary)
                Button("Run Speed Test") { }.buttonStyle(.glassProminent).disabled(true)
                Label("A future test will use only a disposable app-owned file; source media will never be modified.", systemImage: "info.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var speedExplanation: String {
        if volume.looksLikeCameraCard { return "Disabled for camera cards to avoid writes beside source media." }
        if volume.isReadOnly || !volume.isWritable { return "This volume does not expose safe write access." }
        return "Safe disposable-file benchmarking is not implemented in this build, so no result is estimated or cached."
    }

    private var diskKind: String {
        if volume.looksLikeCameraCard { return "Camera Card" }
        if volume.storageCategory == .internalStorage { return "Internal Storage" }
        return "External Disk"
    }

    private var diskSymbol: String {
        if volume.looksLikeCameraCard { return "sdcard.fill" }
        if volume.isInternal { return "internaldrive.fill" }
        return "externaldrive.fill"
    }

    private func inspectorSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.3)))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func healthRow(_ title: String, passed: Bool, success: String, failure: String = "Unavailable") -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Image(systemName: passed ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(passed ? .green : .secondary)
            Text(passed ? success : failure)
        }
        .font(.caption)
    }

    private func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct CapacityBar: View {
    let volume: MountedVolume

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(fillColor).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 7)
        .accessibilityLabel("Storage used")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    private var fraction: CGFloat {
        guard volume.totalBytes > 0 else { return 0 }
        return min(1, max(0, CGFloat(volume.usedBytes) / CGFloat(volume.totalBytes)))
    }
    private var fillColor: Color { fraction > 0.9 ? .orange : .blue }
}
