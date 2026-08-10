import AppKit
import Foundation
import Observation

struct MountedVolume: Identifiable, Hashable {
    let url: URL
    let name: String
    /// A `DCIM/` or `PRIVATE/` folder at the root is the near-universal
    /// camera-card signature.
    let looksLikeCameraCard: Bool
    let fileSystem: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool
    let isReadOnly: Bool
    let isReadable: Bool
    let isWritable: Bool
    let volumeIdentifier: String?

    var id: String { url.path }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    /// Non-card external storage is a destination candidate. Internal storage
    /// remains visible in All without being mislabeled as a configured target.
    var isDestinationCandidate: Bool {
        !looksLikeCameraCard && (!isInternal || isRemovable || isEjectable)
    }
    var connectionDescription: String {
        if isRemovable { return "Removable media" }
        if isEjectable { return "External, ejectable" }
        if isInternal { return "Internal" }
        return "External"
    }
    var storageCategory: MountedStorageCategory {
        if looksLikeCameraCard { return .cameraCard }
        if isInternal && !isRemovable && !isEjectable { return .internalStorage }
        return .externalDisk
    }

    init(
        url: URL,
        name: String,
        looksLikeCameraCard: Bool,
        fileSystem: String = "Unknown",
        totalBytes: Int64 = 0,
        availableBytes: Int64 = 0,
        isRemovable: Bool = false,
        isEjectable: Bool = false,
        isInternal: Bool = false,
        isReadOnly: Bool = false,
        isReadable: Bool = true,
        isWritable: Bool = false,
        volumeIdentifier: String? = nil
    ) {
        self.url = url
        self.name = name
        self.looksLikeCameraCard = looksLikeCameraCard
        self.fileSystem = fileSystem
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.volumeIdentifier = volumeIdentifier
    }
}

enum MountedStorageCategory: String, CaseIterable, Sendable {
    case internalStorage
    case externalDisk
    case cameraCard
}

/// Watches volume mounts so the dashboard can offer one-click offload the
/// moment a card appears. Observation only — nothing here reads media, and
/// nothing offloads without an explicit user click.
@MainActor
@Observable
final class VolumeWatcher {
    private(set) var volumes: [MountedVolume] = []
    var onCardMounted: ((MountedVolume) -> Void)?
    var onVolumesChanged: (([MountedVolume]) -> Void)?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Pull the Sendable URL out before hopping into isolation; the
            // Notification itself must not cross.
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if let url,
                   let mounted = self.volumes.first(where: { $0.url == url }),
                   mounted.looksLikeCameraCard {
                    self.onCardMounted?(mounted)
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func refresh() {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
            .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey,
        ]
        var urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        // APFS volume groups do not consistently include `/` in this API's
        // result, even though it is the Mac's primary mounted storage.
        let startupURL = URL(fileURLWithPath: "/", isDirectory: true)
        if !urls.contains(where: { $0.standardizedFileURL.path == "/" }) {
            urls.insert(startupURL, at: 0)
        }
        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let external = (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || !(values.volumeIsInternal ?? true)
            // Include the Mac's user-visible startup volume in addition to
            // external media. Other hidden/system helper volumes remain out.
            let isStartupVolume = url.standardizedFileURL.path == "/"
            guard isStartupVolume || external else { return nil }
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                looksLikeCameraCard: !isStartupVolume && external && Self.looksLikeCard(url),
                fileSystem: values.volumeLocalizedFormatDescription ?? "Unknown",
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                isReadOnly: values.volumeIsReadOnly ?? false,
                isReadable: FileManager.default.isReadableFile(atPath: url.path),
                isWritable: !(values.volumeIsReadOnly ?? false)
                    && FileManager.default.isWritableFile(atPath: url.path),
                volumeIdentifier: values.volumeUUIDString
            )
        }
        .sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        onVolumesChanged?(volumes)
    }

    static func looksLikeCard(_ root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("DCIM").path)
            || fm.fileExists(atPath: root.appendingPathComponent("PRIVATE").path)
    }
}
