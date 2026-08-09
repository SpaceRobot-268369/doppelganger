import Foundation

/// Persists the chosen source and destinations across launches. Plain paths,
/// because the MVP is not sandboxed; a security-scoped-bookmark store replaces
/// this type (and nothing else) when sandboxing arrives.
protocol SelectionStore {
    func load() -> (source: URL?, destinations: [URL])
    func save(source: URL?, destinations: [URL])
}

struct UserDefaultsSelectionStore: SelectionStore {
    private let defaults: UserDefaults
    private static let sourceKey = "selection.sourcePath"
    private static let destinationsKey = "selection.destinationPaths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> (source: URL?, destinations: [URL]) {
        let source = defaults.string(forKey: Self.sourceKey).map { URL(fileURLWithPath: $0) }
        let destinations = (defaults.stringArray(forKey: Self.destinationsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        return (source, destinations)
    }

    func save(source: URL?, destinations: [URL]) {
        defaults.set(source?.path, forKey: Self.sourceKey)
        defaults.set(destinations.map(\.path), forKey: Self.destinationsKey)
    }
}
