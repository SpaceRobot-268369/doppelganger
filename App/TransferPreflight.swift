import Foundation

/// Immutable review result shown before an offload may start. The engine repeats
/// the safety checks; this layer exists so the operator sees the exact plan.
struct TransferPreflight: Sendable, Equatable {
    enum SourceMHLStatus: Sendable, Equatable {
        case absent
        case trusted
        case untrusted(String)
    }
    struct Destination: Sendable, Equatable, Identifiable {
        let base: URL
        let output: URL
        let volume: FileSystemVolume?
        let availableBytes: Int64?
        let duplicateManifest: TransferManifest?

        var id: URL { base }
    }

    let source: URL
    let folderName: String
    /// Whether the files land in a new folder inside each destination or
    /// straight into it.
    let layout: DestinationLayout
    /// The exact items requested from the source, relative to it, or `nil` when
    /// the whole source is being transferred. The engine receives this same set
    /// so it copies precisely what was reviewed.
    let includedRelativePaths: Set<String>?
    /// The reviewed source plan. The review page renders its file tree from
    /// this, so browsing the plan costs no additional disk access.
    let items: [SourceItem]
    let itemCount: Int
    let totalBytes: Int64
    /// How many files the source holds in total, when only some were selected.
    let sourceItemCount: Int
    let sourceFingerprint: String
    let mediaAnalysis: MediaAnalysisSummary
    let zeroBytePaths: [String]
    let sourceVolume: FileSystemVolume?
    let sourceMHLStatus: SourceMHLStatus
    let destinations: [Destination]
    let blockingIssues: [String]
    let warnings: [String]
    let notices: [String]

    var canStart: Bool { blockingIssues.isEmpty }
    var requiresAcknowledgement: Bool { !warnings.isEmpty }

    var requestDestinations: [TransferDestination] {
        destinations.map { TransferDestination(baseRoot: $0.base, outputRoot: $0.output) }
    }

    func matches(
        source: URL?,
        destinations: [URL],
        folderName: String,
        layout: DestinationLayout = .newFolder,
        includedRelativePaths: Set<String>? = nil
    ) -> Bool {
        guard let source else { return false }
        return self.source.standardizedFileURL == source.standardizedFileURL
            && self.destinations.map(\.base.standardizedFileURL)
                == destinations.map(\.standardizedFileURL)
            && self.folderName == Self.validFolderName(folderName)
            && self.layout == layout
            && self.includedRelativePaths == includedRelativePaths
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

    /// Industry-style transfer folder name: a compact date stamp and the reel
    /// or card it came from — `20260810_A001`.
    static func defaultFolderName(for source: URL, at date: Date = Date()) -> String {
        defaultFolderName(reel: reelName(for: source), at: date)
    }

    /// The reel/tape name a source implies, in the camera department's
    /// convention: a camera letter and a three-digit tape number — `A001`.
    ///
    /// A card already named that way keeps its own reel. Anything else falls
    /// back to the A camera's next tape, so the default always reads like a
    /// reel; it is shown in Shooting Info and stays editable.
    ///
    /// - Parameter position: where this source sits in the plan, so a batch of
    ///   unnamed cards defaults to A001, A002, … instead of one repeated name.
    static func reelName(for source: URL, position: Int = 0) -> String {
        conventionalReel(in: source.lastPathComponent) ?? defaultReel(position: position)
    }

    /// Pulls a reel out of a card name: `A001` → `A001`, `CANON_C012_01` →
    /// `C012`, `100_FUJI` → none. The letter must stand on its own; a longer
    /// word is a make or a model, not a camera letter.
    static func conventionalReel(in name: String) -> String? {
        let characters = Array(name.uppercased())
        for index in characters.indices where characters[index].isLetter {
            if index > 0, characters[index - 1].isLetter { continue }
            let digits = characters[(index + 1)...].prefix { $0.isNumber }
            guard digits.count == 3 else { continue }
            let after = index + 1 + digits.count
            guard after == characters.count || !characters[after].isLetter else { continue }
            return String(characters[index]) + String(digits)
        }
        return nil
    }

    static func defaultReel(position: Int) -> String {
        String(format: "A%03d", max(position, 0) + 1)
    }

    static func defaultFolderName(reel: String, at date: Date = Date()) -> String {
        validFolderName("\(dateStamp(date))_\(reel.uppercased())")
    }

    /// The operator's local calendar date. ISO-8601 formatting defaults to GMT,
    /// which names a card offloaded in the morning after the previous day in
    /// western time zones and the next day in eastern ones.
    static func dateStamp(_ date: Date = Date()) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .omitted, timeZone: .current)
                .year().month().day()
        )
    }

    static func inspect(
        source: URL,
        destinationBases: [URL],
        folderName rawName: String,
        algorithm: ChecksumAlgorithm = .xxh3,
        layout: DestinationLayout = .newFolder,
        includedRelativePaths: Set<String>? = nil
    ) async -> Self {
        await Task.detached(priority: .userInitiated) {
            let fileSystem = RealFileSystem()
            let folderName = validFolderName(rawName)
            var blocking: [String] = []
            var warnings: [String] = []
            var notices: [String] = []
            var items: [SourceItem] = []
            var sourceItemCount = 0
            // The engine keys on exact relative paths; a selected folder is
            // expanded here into the files it actually contains.
            var resolvedSelection: Set<String>?

            if folderName.isEmpty, layout == .newFolder {
                blocking.append("Enter a name for the new transfer folder.")
            }
            do {
                items = try fileSystem.enumerate(root: source)
                sourceItemCount = items.count
                if let requested = includedRelativePaths, !requested.isEmpty {
                    let selected = items.filter { item in
                        requested.contains(item.relativePath)
                            || requested.contains { item.relativePath.hasPrefix($0 + "/") }
                    }
                    let matched = Set(selected.flatMap { item -> [String] in
                        requested.filter {
                            item.relativePath == $0 || item.relativePath.hasPrefix($0 + "/")
                        }
                    })
                    let missing = requested.subtracting(matched).sorted()
                    if !missing.isEmpty {
                        blocking.append(
                            "Selected item(s) are no longer in the source: "
                            + missing.prefix(5).joined(separator: ", ")
                        )
                    }
                    items = selected
                    resolvedSelection = Set(selected.map(\.relativePath))
                    if selected.isEmpty && missing.isEmpty {
                        blocking.append("Nothing was selected from the source.")
                    }
                    notices.append(
                        "Only the \(selected.count) selected item(s) will be transferred; "
                        + "the rest of \(source.lastPathComponent) is left alone."
                    )
                }
                if items.isEmpty, blocking.isEmpty { blocking.append("The source is empty.") }
            } catch {
                blocking.append("The source could not be scanned: \(error)")
            }
            let zeroByte = items.filter { $0.size == 0 }.map(\.relativePath)
            if !zeroByte.isEmpty {
                blocking.append("\(zeroByte.count) zero-byte source file(s) must be investigated before offload.")
            }
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            let mediaAnalysis = await MediaAnalyzer.analyze(root: source, items: items)
            for finding in mediaAnalysis.findings where finding.severity == .error && finding.code == "unreadable" {
                blocking.append(
                    "Unreadable source file: \(finding.relativePath ?? finding.message)"
                )
            }
            let sourceCanonical = fileSystem.canonicalURL(source)
            let sourceVolume = try? fileSystem.volume(at: source)
            let sourceMHLInspection = SourceMHLTrust.inspect(
                sourceRoot: source,
                items: items,
                algorithm: algorithm,
                expectedFingerprint: planFingerprint(items),
                fileSystem: fileSystem
            )
            let sourceMHLStatus: SourceMHLStatus = switch sourceMHLInspection.state {
            case .absent: .absent
            case .trusted: .trusted
            case .validButUntrusted(let reason): .untrusted(reason)
            }
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
                let output = layout == .newFolder
                    ? base.appendingPathComponent(folderName, isDirectory: true)
                    : base
                let canonicalOutput = fileSystem.canonicalURL(output)
                var duplicateManifest: TransferManifest?
                if canonicalOutput.path == sourceCanonical.path
                    || canonicalOutput.path.hasPrefix(sourceCanonical.path + "/")
                    || sourceCanonical.path.hasPrefix(canonicalOutput.path + "/") {
                    blocking.append("Source and output folders overlap: \(base.path)")
                }
                if fileSystem.fileExists(at: output) {
                    duplicateManifest = verifiedDuplicateCandidate(
                        at: output,
                        sourceFingerprint: planFingerprint(items),
                        algorithm: algorithm
                    )
                    // Writing directly into a destination means the output
                    // always exists; the guarantee there is that the engine
                    // never overwrites, not that the folder starts empty.
                    if duplicateManifest == nil, layout == .newFolder {
                        blocking.append("Output folder already exists: \(output.path)")
                    } else if duplicateManifest != nil {
                        notices.append(
                            "\(base.lastPathComponent) has a prior verified candidate. The engine will hash source and destination independently before skipping any file."
                        )
                    }
                }
                if layout == .directly {
                    let existing = collidingNames(items: items, output: output, fileSystem: fileSystem)
                    if !existing.isEmpty {
                        blocking.append(
                            "\(base.lastPathComponent) already contains "
                            + existing.prefix(3).joined(separator: ", ")
                            + ". Nothing is ever overwritten, so those files would fail."
                        )
                    }
                }

                let volume = try? fileSystem.volume(at: base)
                if volume?.isReadOnly == true {
                    blocking.append("Destination is read-only: \(base.path)")
                }
                let available = volume?.availableBytes ?? (try? fileSystem.freeSpace(at: base))
                let reserve = max(Int64(512 * 1024 * 1024), total / 20)
                // A prior verified manifest only excuses the files it can
                // plausibly prove; the rest of the plan still needs room. A
                // plan it covers entirely needs none here; the engine
                // re-checks capacity once it knows what it must write.
                let candidateBytes = duplicateManifest.map {
                    duplicateCandidateBytes(items: items, manifest: $0, output: output)
                } ?? 0
                let remainder = total - candidateBytes
                let needed = remainder + reserve
                if remainder > 0, let available, available < needed {
                    blocking.append(
                        "Not enough working space on \(volume?.name ?? base.lastPathComponent): "
                        + "needs \(Format.bytes(needed)), has \(Format.bytes(available))."
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
                    availableBytes: available,
                    duplicateManifest: duplicateManifest
                ))
            }

            for names in destinationVolumes.values where names.count > 1 {
                warnings.append(
                    "\(names.joined(separator: " and ")) share one physical volume; they are not independent copies."
                )
            }

            if layout == .directly, !reviewedDestinations.isEmpty {
                notices.append(
                    "Files are written straight into \(reviewedDestinations.count) destination(s) with no new folder."
                )
            }

            return TransferPreflight(
                source: source,
                folderName: folderName,
                layout: layout,
                includedRelativePaths: resolvedSelection,
                items: items,
                itemCount: items.count,
                totalBytes: total,
                sourceItemCount: sourceItemCount,
                sourceFingerprint: planFingerprint(items),
                mediaAnalysis: mediaAnalysis,
                zeroBytePaths: zeroByte,
                sourceVolume: sourceVolume,
                sourceMHLStatus: sourceMHLStatus,
                destinations: reviewedDestinations,
                blockingIssues: Array(Set(blocking)).sorted(),
                warnings: Array(Set(warnings)).sorted(),
                notices: Array(Set(notices)).sorted()
            )
        }.value
    }

    /// Paths that already exist where the plan wants to write them. Only
    /// meaningful when writing directly into a destination, where the output
    /// is not guaranteed to start empty.
    static func collidingNames(
        items: [SourceItem],
        output: URL,
        fileSystem: any FileSystemAccess
    ) -> [String] {
        items.lazy
            .filter { fileSystem.fileExists(at: output.appendingPathComponent($0.relativePath)) }
            .map(\.relativePath)
            .prefix(20)
            .sorted()
    }

    private static func verifiedDuplicateCandidate(
        at output: URL,
        sourceFingerprint: String,
        algorithm: ChecksumAlgorithm
    ) -> TransferManifest? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var candidates: [TransferManifest] = []
        for file in files where file.lastPathComponent.hasPrefix("doppelganger-manifest-")
            && file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? ManifestWriter.decode(data),
                  manifest.status == TransferStatus.verified.rawValue,
                  manifest.sourceFingerprint == sourceFingerprint,
                  (manifest.algorithm == algorithm.rawValue
                    || (manifest.algorithm == "xxh64" && algorithm == .xxh64)),
                  manifest.destinations.contains(where: { $0.path == output.path })
            else { continue }
            candidates.append(manifest)
        }
        return candidates.sorted { $0.finishedAt > $1.finishedAt }.first
    }

    /// Bytes a prior verified manifest might let the engine skip at `output`:
    /// same relative path and size, a recorded digest, and a verified result
    /// there. The engine re-hashes before skipping anything, and re-checks
    /// capacity against the exact remainder once it has.
    static func duplicateCandidateBytes(
        items: [SourceItem],
        manifest: TransferManifest,
        output: URL
    ) -> Int64 {
        let records = Dictionary(
            manifest.items.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return items.reduce(Int64(0)) { sum, item in
            guard let record = records[item.relativePath],
                  record.size == item.size,
                  record.digest != nil,
                  record.results.contains(where: {
                      $0.destination == output.path && $0.status == "verified"
                  })
            else { return sum }
            return sum + item.size
        }
    }

    /// Stable identity of the reviewed source plan. Paths, sizes, and source
    /// timestamps are included; matching this value is stronger than matching
    /// a volume label but is still only a candidate until digests verify.
    static func planFingerprint(_ items: [SourceItem]) -> String {
        SourcePlanFingerprint.make(items)
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
