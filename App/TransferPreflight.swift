import Foundation

/// Immutable review result shown before an offload may start. The engine repeats
/// the safety checks; this layer exists so the operator sees the exact plan.
struct TransferPreflight: Sendable, Equatable {
    struct Destination: Sendable, Equatable, Identifiable {
        let base: URL
        let output: URL
        let volume: FileSystemVolume?
        let availableBytes: Int64?

        var id: URL { base }
    }

    let source: URL
    let folderName: String
    let itemCount: Int
    let totalBytes: Int64
    let zeroBytePaths: [String]
    let sourceVolume: FileSystemVolume?
    let destinations: [Destination]
    let blockingIssues: [String]
    let warnings: [String]

    var canStart: Bool { blockingIssues.isEmpty }
    var requiresAcknowledgement: Bool { !warnings.isEmpty }

    var requestDestinations: [TransferDestination] {
        destinations.map { TransferDestination(baseRoot: $0.base, outputRoot: $0.output) }
    }

    func matches(source: URL?, destinations: [URL], folderName: String) -> Bool {
        guard let source else { return false }
        return self.source.standardizedFileURL == source.standardizedFileURL
            && self.destinations.map(\.base.standardizedFileURL)
                == destinations.map(\.standardizedFileURL)
            && self.folderName == Self.validFolderName(folderName)
    }

    static func validFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/:\0").union(.controlCharacters)
        let scalars = trimmed.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }
        let collapsed = scalars.joined()
            .replacingOccurrences(of: "..", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(collapsed.prefix(120))
    }

    static func defaultFolderName(for source: URL, at date: Date = Date()) -> String {
        let stamp = String(date.formatted(.iso8601).prefix(10))
        return validFolderName("\(stamp)_\(source.lastPathComponent.uppercased())")
    }

    static func inspect(source: URL, destinationBases: [URL], folderName rawName: String) async -> Self {
        await Task.detached(priority: .userInitiated) {
            let fileSystem = RealFileSystem()
            let folderName = validFolderName(rawName)
            var blocking: [String] = []
            var warnings: [String] = []
            var items: [SourceItem] = []

            if folderName.isEmpty {
                blocking.append("Enter a name for the new transfer folder.")
            }
            do {
                items = try fileSystem.enumerate(root: source)
                if items.isEmpty { blocking.append("The source is empty.") }
            } catch {
                blocking.append("The source could not be scanned: \(error)")
            }
            let zeroByte = items.filter { $0.size == 0 }.map(\.relativePath)
            if !zeroByte.isEmpty {
                blocking.append("\(zeroByte.count) zero-byte source file(s) must be investigated before offload.")
            }
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            let sourceCanonical = fileSystem.canonicalURL(source)
            let sourceVolume = try? fileSystem.volume(at: source)
            var reviewedDestinations: [Destination] = []
            var seenPaths = Set<String>()
            var destinationVolumes: [String: [String]] = [:]

            for base in destinationBases {
                let canonicalBase = fileSystem.canonicalURL(base)
                guard seenPaths.insert(canonicalBase.path).inserted else {
                    blocking.append("The same destination is listed more than once: \(base.path)")
                    continue
                }
                guard fileSystem.fileExists(at: base) else {
                    blocking.append("Destination is not mounted: \(base.path)")
                    continue
                }
                let output = base.appendingPathComponent(folderName, isDirectory: true)
                let canonicalOutput = fileSystem.canonicalURL(output)
                if canonicalOutput.path == sourceCanonical.path
                    || canonicalOutput.path.hasPrefix(sourceCanonical.path + "/")
                    || sourceCanonical.path.hasPrefix(canonicalOutput.path + "/") {
                    blocking.append("Source and output folders overlap: \(base.path)")
                }
                if fileSystem.fileExists(at: output) {
                    blocking.append("Output folder already exists: \(output.path)")
                }

                let volume = try? fileSystem.volume(at: base)
                if volume?.isReadOnly == true {
                    blocking.append("Destination is read-only: \(base.path)")
                }
                let available = volume?.availableBytes ?? (try? fileSystem.freeSpace(at: base))
                let reserve = max(Int64(512 * 1024 * 1024), total / 20)
                if let available, available < total + reserve {
                    blocking.append(
                        "Not enough working space on \(volume?.name ?? base.lastPathComponent): "
                        + "needs \(Format.bytes(total + reserve)), has \(Format.bytes(available))."
                    )
                }
                if let sourceVolume, let volume, sourceVolume.identifier == volume.identifier {
                    let sourceIsMountedRoot = sourceCanonical.path == sourceVolume.mountPath
                    if sourceIsMountedRoot && sourceVolume.isRemovable {
                        blocking.append("A camera-card source cannot also be its own destination volume.")
                    } else {
                        warnings.append(
                            "\(base.lastPathComponent) is on the same volume as the source; this is not an independent backup."
                        )
                    }
                }
                if let volume {
                    destinationVolumes[volume.identifier, default: []].append(base.lastPathComponent)
                    blocking.append(contentsOf: compatibilityIssues(
                        items: items,
                        output: output,
                        volume: volume
                    ))
                }
                reviewedDestinations.append(Destination(
                    base: base,
                    output: output,
                    volume: volume,
                    availableBytes: available
                ))
            }

            for names in destinationVolumes.values where names.count > 1 {
                warnings.append(
                    "\(names.joined(separator: " and ")) share one physical volume; they are not independent copies."
                )
            }

            return TransferPreflight(
                source: source,
                folderName: folderName,
                itemCount: items.count,
                totalBytes: total,
                zeroBytePaths: zeroByte,
                sourceVolume: sourceVolume,
                destinations: reviewedDestinations,
                blockingIssues: Array(Set(blocking)).sorted(),
                warnings: Array(Set(warnings)).sorted()
            )
        }.value
    }

    static func compatibilityIssues(
        items: [SourceItem],
        output: URL,
        volume: FileSystemVolume
    ) -> [String] {
        var issues: [String] = []
        if volume.supportsCaseSensitiveNames == false {
            let collisions = Dictionary(grouping: items) {
                $0.relativePath.precomposedStringWithCanonicalMapping
                    .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            }.values.filter { $0.count > 1 }
            if let collision = collisions.first {
                issues.append(
                    "\(volume.name) is case-insensitive, but these source paths collide: "
                    + collision.prefix(3).map(\.relativePath).joined(separator: ", ")
                )
            }
        }

        if let limit = volume.maximumNameBytes,
           let item = items.first(where: {
               $0.relativePath.split(separator: "/").contains { $0.utf8.count > limit }
           }) {
            issues.append(
                "A filename exceeds \(volume.name)'s \(limit)-byte limit: \(item.relativePath)"
            )
        }
        if let limit = volume.maximumPathBytes,
           let item = items.first(where: {
               output.appendingPathComponent($0.relativePath).path.utf8.count + 1 > limit
           }) {
            issues.append(
                "An output path exceeds \(volume.name)'s \(limit)-byte limit: \(item.relativePath)"
            )
        }
        return issues
    }
}
