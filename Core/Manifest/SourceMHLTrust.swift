import Foundation

struct SourceMHLInspection: Sendable {
    enum State: Sendable {
        case absent
        case validButUntrusted(String)
        case trusted
    }

    let state: State
    let digests: [String: String]
}

enum SourceMHLTrust {
    static func inspect(
        sourceRoot: URL,
        items: [SourceItem],
        algorithm: ChecksumAlgorithm,
        expectedFingerprint: String?,
        fileSystem: any FileSystemAccess
    ) -> SourceMHLInspection {
        let directory = sourceRoot.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        guard fileSystem.fileExists(at: chainURL) else {
            return SourceMHLInspection(state: .absent, digests: [:])
        }
        do {
            let chain = try MHLReader.validateChain(at: directory, fileSystem: fileSystem)
            guard let latest = chain.entries.last else {
                return untrusted("The ASC MHL history has no generations.")
            }
            let data = try MHLReader.readAll(
                directory.appendingPathComponent(latest.path),
                fileSystem: fileSystem
            )
            let document = try MHLReader.read(data)
            guard document.version == "2.0" else {
                return untrusted("Only ASC MHL v2 histories can provide trusted source digests.")
            }
            let fingerprint = SourcePlanFingerprint.make(items)
            guard let recordedFingerprint = document.sourcePlanFingerprint,
                  recordedFingerprint == fingerprint,
                  expectedFingerprint == nil || expectedFingerprint == fingerprint
            else {
                return untrusted("The ASC MHL source-plan identity does not match this source.")
            }
            let volumeID = try fileSystem.volume(at: sourceRoot).identifier
            guard document.mediaVolumeIdentifier == volumeID else {
                return untrusted("The ASC MHL volume identity does not match the mounted source.")
            }

            let records = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.relativePath, $0) })
            guard records.count == items.count else {
                return untrusted("The ASC MHL file set does not match the reviewed source plan.")
            }
            let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            var digests: [String: String] = [:]
            for item in items {
                guard let record = records[item.relativePath],
                      record.size == item.size,
                      let digest = record.digests[algorithm]
                else {
                    return untrusted("ASC MHL is missing a matching \(algorithm.displayName) record for \(item.relativePath).")
                }
                if let modifiedAt = record.modifiedAt,
                   let recordedDate = try? Date(modifiedAt, strategy: iso),
                   let current = item.modificationTime,
                   abs(recordedDate.timeIntervalSince1970 - current) > 0.001 {
                    return untrusted("The source timestamp changed for \(item.relativePath).")
                }
                digests[item.relativePath] = digest
            }

            let calculated = DirectoryHashes.calculate(
                items: items.compactMap { item in
                    digests[item.relativePath].map {
                        ItemResult(item: item, sourceDigest: $0, outcomes: [:])
                    }
                },
                algorithm: algorithm
            )
            guard let root = calculated.first(where: { $0.path == "." }),
                  document.rootContentDigests[algorithm] == root.content,
                  document.rootStructureDigests[algorithm] == root.structure
            else {
                return untrusted("The ASC MHL root directory hash does not match its file records.")
            }
            let expectedDirectories: [String: (String, String)] = Dictionary(uniqueKeysWithValues: calculated
                .filter { $0.path != "." }
                .map { ($0.path, ($0.content, $0.structure)) })
            let recordedDirectories: [String: (String, String)] = Dictionary(uniqueKeysWithValues: document.directories.compactMap {
                guard let content = $0.contentDigests[algorithm],
                      let structure = $0.structureDigests[algorithm] else { return nil }
                return ($0.relativePath, (content, structure))
            })
            guard expectedDirectories.count == recordedDirectories.count,
                  expectedDirectories.allSatisfy({ path, hashes in
                      recordedDirectories[path].map {
                          $0.0 == hashes.0 && $0.1 == hashes.1
                      } == true
                  })
            else {
                return untrusted("The ASC MHL directory hashes do not match its file records.")
            }
            return SourceMHLInspection(state: .trusted, digests: digests)
        } catch {
            return untrusted(error.localizedDescription)
        }
    }

    private static func untrusted(_ reason: String) -> SourceMHLInspection {
        SourceMHLInspection(state: .validButUntrusted(reason), digests: [:])
    }
}
