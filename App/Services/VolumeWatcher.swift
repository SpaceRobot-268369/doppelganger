import AppKit
import Foundation
import Observation

struct MountedVolume: Identifiable, Hashable {
    let url: URL
    let name: String
    /// A `DCIM/` or `PRIVATE/` folder at the root is the near-universal
    /// camera-card signature.
    let looksLikeCameraCard: Bool

    var id: String { url.path }
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
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        volumes = urls.compactMap { url in
            guard url.path != "/",
                  let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let external = (values.volumeIsRemovable ?? false)
                || (values.volumeIsEjectable ?? false)
                || !(values.volumeIsInternal ?? true)
            guard external else { return nil }
            return MountedVolume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                looksLikeCameraCard: Self.looksLikeCard(url)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        onVolumesChanged?(volumes)
    }

    static func looksLikeCard(_ root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("DCIM").path)
            || fm.fileExists(atPath: root.appendingPathComponent("PRIVATE").path)
    }
}
