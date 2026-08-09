import Foundation
@testable import Doppelganger

/// Builds synthetic camera-card-shaped fixtures in a scratch directory under
/// the system temp dir, and tears the whole thing down on deinit.
///
/// Per AGENTS.md Principle 3, tests exercise the engine against these fixtures
/// ONLY — never against real camera cards, external volumes, or user footage.
final class FixtureBuilder {
    let root: URL
    private let manager = FileManager()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? manager.removeItem(at: root)
    }

    /// A file spec: relative path plus deterministic content.
    struct FileSpec {
        let path: String
        let size: Int
        let seed: UInt64

        init(_ path: String, size: Int, seed: UInt64) {
            self.path = path
            self.size = size
            self.seed = seed
        }

        var bytes: [UInt8] { SplitMix64.bytes(count: size, seed: seed) }
    }

    /// Create a synthetic "card" folder containing the given files.
    @discardableResult
    func makeCard(named name: String = "card", files: [FileSpec]) throws -> URL {
        let card = root.appendingPathComponent(name, isDirectory: true)
        for spec in files {
            let fileURL = card.appendingPathComponent(spec.path)
            try manager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(spec.bytes).write(to: fileURL)
        }
        return card
    }

    /// Create an empty destination directory.
    func makeDestination(named name: String) throws -> URL {
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    func bytes(at url: URL) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: url))
    }

    /// relativePath → xxh64 digest for every regular file under `directory`.
    /// Used to assert a source tree was not touched by a failing transfer.
    func digestSnapshot(of directory: URL) throws -> [String: String] {
        let resolved = directory.resolvingSymlinksInPath()
        var snapshot: [String: String] = [:]
        guard let enumerator = manager.enumerator(
            at: resolved,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return snapshot }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(resolved.path.count + 1))
            var hasher = XXHash64()
            let content = [UInt8](try Data(contentsOf: url))
            content.withUnsafeBytes { hasher.update($0) }
            snapshot[relative] = hasher.hexDigest()
        }
        return snapshot
    }
}
