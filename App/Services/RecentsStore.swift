import Foundation

/// Remembers recently used sources and destinations so the Sources and
/// Destinations sidebar pages have something to show across launches.
/// Plain paths, same caveat as `SelectionStore`.
struct RecentsStore {
    private let defaults: UserDefaults
    private static let sourcesKey = "recents.sourcePaths"
    private static let destinationsKey = "recents.destinationPaths"
    private static let capacity = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sources() -> [URL] {
        (defaults.stringArray(forKey: Self.sourcesKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func destinations() -> [URL] {
        (defaults.stringArray(forKey: Self.destinationsKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func noteTransfer(source: URL, destinations: [URL]) {
        defaults.set(prepending(source.path, to: defaults.stringArray(forKey: Self.sourcesKey) ?? []),
                     forKey: Self.sourcesKey)
        var paths = defaults.stringArray(forKey: Self.destinationsKey) ?? []
        for destination in destinations.reversed() {
            paths = prepending(destination.path, to: paths)
        }
        defaults.set(paths, forKey: Self.destinationsKey)
    }

    func removeSource(_ url: URL) {
        defaults.set((defaults.stringArray(forKey: Self.sourcesKey) ?? []).filter { $0 != url.path },
                     forKey: Self.sourcesKey)
    }

    func removeDestination(_ url: URL) {
        defaults.set((defaults.stringArray(forKey: Self.destinationsKey) ?? []).filter { $0 != url.path },
                     forKey: Self.destinationsKey)
    }

    private func prepending(_ path: String, to existing: [String]) -> [String] {
        var paths = existing.filter { $0 != path }
        paths.insert(path, at: 0)
        return Array(paths.prefix(Self.capacity))
    }
}
