import Foundation

struct VerificationReference: Sendable {
    struct Entry: Sendable {
        let relativePath: String
        let size: Int64
        /// `nil` when the reference lists the file but holds no usable digest
        /// for it (a doppelganger manifest item whose source was never read).
        /// Such an entry is still expected in the folder and can never verify.
        let digest: String?
    }

    let algorithm: ChecksumAlgorithm
    let entries: [Entry]
    let sourceDescription: String

    static func load(from url: URL) throws -> VerificationReference {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json",
           let manifest = try? ManifestWriter.decode(data),
           let algorithm = manifest.algorithm == "xxh64"
                ? ChecksumAlgorithm.xxh64
                : ChecksumAlgorithm(rawValue: manifest.algorithm) {
            // Every listed item stays expected. Dropping digest-less items
            // (never read by a paused, cancelled, or failed attempt) would let
            // their absence from the folder pass unnoticed.
            let entries = manifest.items.map {
                Entry(relativePath: $0.relativePath, size: $0.size, digest: $0.digest)
            }
            guard entries.contains(where: { $0.digest != nil }) else { throw MHLReadError.noHashes }
            return VerificationReference(
                algorithm: algorithm,
                entries: entries,
                sourceDescription: url.lastPathComponent
            )
        }

        let document = try MHLReader.read(data)
        // A record the MHL marks "failed" holds the hash of bytes already
        // proven wrong; using it as the expected value would verify the damage
        // against itself. Refuse the whole reference and name the file.
        let untrusted = document.entries.compactMap { entry in
            entry.untrustedHashAction.map { (path: entry.relativePath, action: $0) }
        }
        if let first = untrusted.first {
            throw MHLReadError.untrustedHashRecord(
                path: first.path,
                action: first.action,
                recordCount: untrusted.count
            )
        }
        // A <hash> record the reader could not use still names a file. Refuse
        // the list rather than let that file's absence go unnoticed.
        guard document.unusableHashRecordCount == 0 else {
            throw MHLReadError.unverifiableHashRecords
        }
        let preference: [ChecksumAlgorithm] = [.xxh3, .xxh64, .md5]
        guard let algorithm = preference.first(where: { candidate in
            document.entries.allSatisfy { $0.digests[candidate] != nil }
        }) else { throw MHLReadError.inconsistentAlgorithms }
        return VerificationReference(
            algorithm: algorithm,
            entries: document.entries.compactMap { entry in
                entry.digests[algorithm].map {
                    Entry(relativePath: entry.relativePath, size: entry.size, digest: $0)
                }
            },
            sourceDescription: url.lastPathComponent
        )
    }
}

enum StandaloneVerificationService {
    static func verify(
        id: UUID,
        referenceURL: URL,
        mediaRoot: URL,
        operatorProfile: OperatorProfile,
        projectID: UUID?,
        spoolDirectory: URL,
        chunkSize: Int = 4 * 1024 * 1024
    ) async throws -> TransferReport {
        try await Task.detached(priority: .userInitiated) {
            let startedAt = Date()
            let reference = try VerificationReference.load(from: referenceURL)
            let fileSystem = RealFileSystem()
            // The chosen reference is the evidence this run checks against, not
            // media: an MHL v1 sits in the root of the folder it describes. Only
            // that one file is set aside, matched by the canonical relative path
            // enumeration produces; any other unlisted file, another .mhl
            // included, is still added. A reference outside the folder sets
            // nothing aside.
            let referenceInsideMedia = try? fileSystem
                .sourceItem(at: referenceURL, relativeTo: mediaRoot)
                .relativePath
            let actualItems = try fileSystem.enumerate(root: mediaRoot).filter {
                !isGeneratedEvidence($0.relativePath) && $0.relativePath != referenceInsideMedia
            }
            let actualPaths = Set(actualItems.map(\.relativePath))
            let expectedPaths = Set(reference.entries.map(\.relativePath))
            let added = actualPaths.subtracting(expectedPaths).sorted()
            var results: [ItemResult] = []
            var buffer = [UInt8](repeating: 0, count: chunkSize)

            for entry in reference.entries {
                try Task.checkCancellation()
                let target = mediaRoot.appendingPathComponent(entry.relativePath)
                let sourceItem = SourceItem(relativePath: entry.relativePath, size: entry.size)
                let outcome: ItemDestinationOutcome
                if !fileSystem.fileExists(at: target) {
                    outcome = .failed(.missingFile)
                } else {
                    do {
                        let observed = try fileSystem.sourceItem(at: target, relativeTo: mediaRoot)
                        if observed.size != entry.size {
                            outcome = .failed(.sizeMismatch(expected: entry.size, actual: observed.size))
                        } else if let expected = entry.digest {
                            let stream = try fileSystem.openForReading(target, uncached: true)
                            defer { stream.close() }
                            var hasher = reference.algorithm.makeHasher()
                            while true {
                                let count = try stream.read(into: &buffer)
                                if count == 0 { break }
                                buffer.withUnsafeBytes { raw in
                                    hasher.update(UnsafeRawBufferPointer(rebasing: raw[0..<count]))
                                }
                            }
                            let actual = hasher.hexDigest()
                            outcome = actual == expected
                                ? .verified
                                : .failed(.checksumMismatch(expected: expected, actual: actual))
                        } else {
                            // Present at the listed size, but the reference
                            // recorded no digest, so nothing proves these are
                            // the source's bytes.
                            outcome = .failed(.noReferenceDigest)
                        }
                    } catch {
                        outcome = .failed(.sourceUnreadable(detail: error.localizedDescription))
                    }
                }
                results.append(ItemResult(
                    item: sourceItem,
                    sourceDigest: entry.digest,
                    outcomes: [mediaRoot: outcome]
                ))
            }

            let allVerified = results.allSatisfy { $0.outcomes[mediaRoot]?.isVerified == true }
            let issues = added.isEmpty
                ? []
                : ["Added files not present in the reference: " + added.prefix(20).joined(separator: ", ")]
            let provisional = TransferReport(
                id: id,
                status: allVerified && added.isEmpty ? .verified : .failed,
                algorithm: reference.algorithm,
                verificationProfile: .standard,
                taskID: id,
                operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                projectID: projectID,
                sourceRoot: mediaRoot,
                destinations: [mediaRoot],
                startedAt: startedAt,
                finishedAt: Date(),
                items: results,
                manifestLocations: [],
                issues: issues
            )
            let spool = spoolDirectory.appendingPathComponent(provisional.shortID, isDirectory: true)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            let manifest = TransferManifest(report: provisional)
            try ManifestWriter.jsonData(for: manifest).write(
                to: spool.appendingPathComponent(
                    ManifestWriter.manifestFileName(shortID: provisional.shortID)
                ),
                options: .atomic
            )
            try Data(MarkdownReportWriter.markdown(for: manifest).utf8).write(
                to: spool.appendingPathComponent(
                    ManifestWriter.reportFileName(shortID: provisional.shortID)
                ),
                options: .atomic
            )
            return TransferReport(
                id: provisional.id,
                status: provisional.status,
                algorithm: provisional.algorithm,
                verificationProfile: provisional.verificationProfile,
                taskID: provisional.taskID,
                operatorSnapshot: provisional.operatorSnapshot,
                projectID: provisional.projectID,
                sourceRoot: provisional.sourceRoot,
                destinations: provisional.destinations,
                startedAt: provisional.startedAt,
                finishedAt: provisional.finishedAt,
                items: provisional.items,
                manifestLocations: [spool],
                issues: provisional.issues
            )
        }.value
    }

    private static func isGeneratedEvidence(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        return name.hasPrefix("doppelganger-manifest-") && name.hasSuffix(".json")
            || name.hasPrefix("doppelganger-report-") && name.hasSuffix(".md")
            || name.hasPrefix("doppelganger-") && name.hasSuffix(".mhl")
            || name.hasPrefix("doppelganger-transfer-") && name.hasSuffix(".log")
    }
}
