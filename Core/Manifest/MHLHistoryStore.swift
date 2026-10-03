import Foundation

struct MHLWriteReceipt: Sendable {
    let destination: URL
    let directory: URL
    let generationURL: URL
    let chainURL: URL
    let previousChainData: Data?
    /// Where the pre-append chain index was archived, `nil` for a first
    /// generation. Recovery restores the chain from this file.
    let archiveURL: URL?
}

/// Transactional filesystem layer for ASC MHL generations. Each manifest is
/// immutable. The spec-defined chain index is atomically updated only after
/// its previous bytes have been archived, and receipts make a multi-drive
/// evidence write reversible until every destination succeeds.
enum MHLHistoryStore {
    /// `parent`, for a repair, is the failed attempt it retries: the pairs it
    /// verified at `destination` join the generation, so a folder's first
    /// history can describe every verified copy rather than only the repaired
    /// ones. Without it a repair's generation lists only its own pairs and so
    /// claims no root hash over the folder.
    static func append(
        report: TransferReport,
        destination: URL,
        carryingVerifiedPairsFrom parent: TransferManifest? = nil,
        fileSystem: any FileSystemAccess
    ) throws -> MHLWriteReceipt? {
        guard report.status == .verified else { return nil }
        let directory = destination.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        let previousChainData: Data?
        let priorEntries: [MHLWriter.ChainEntry]
        var history: [MHLDocument.Entry] = []
        if fileSystem.fileExists(at: chainURL) {
            let data = try MHLReader.readAll(chainURL, fileSystem: fileSystem)
            let chain = try MHLReader.readChain(data)
            for entry in chain.entries {
                let generationData = try MHLReader.readAll(
                    directory.appendingPathComponent(entry.path),
                    fileSystem: fileSystem
                )
                guard C4Checksum.digest(generationData) == entry.c4 else {
                    throw MHLReadError.chainDigestMismatch(path: entry.path)
                }
                history += try MHLReader.read(generationData).entries
            }
            previousChainData = data
            priorEntries = chain.entries.map {
                MHLWriter.ChainEntry(sequence: $0.sequence, path: $0.path, c4: $0.c4)
            }
        } else {
            previousChainData = nil
            priorEntries = []
        }

        let sequence = (priorEntries.last?.sequence ?? 0) + 1
        let carried = try carriedRecords(
            from: parent,
            report: report,
            destination: destination,
            fileSystem: fileSystem
        )
        // A folder that cannot be listed gets no directory hashes rather than
        // ones nothing proves.
        let folderMedia = (try? fileSystem.enumerate(root: destination)).map { Set($0.map(\.relativePath)) }
        guard let generation = try MHLWriter.generation(
            for: report,
            destination: destination,
            sequence: sequence,
            context: MHLWriter.FolderContext(history: history, carried: carried, folderMedia: folderMedia),
            mediaVolumeIdentifier: try? fileSystem.volume(at: destination).identifier
        ) else { return nil }
        // Nothing is written until the generation is decided.
        try fileSystem.createDirectory(at: directory)
        let generationURL = directory.appendingPathComponent(generation.fileName)
        try writeExclusive(generation.data, to: generationURL, fileSystem: fileSystem)

        do {
            let nextEntries = priorEntries + [MHLWriter.ChainEntry(
                sequence: sequence,
                path: generation.fileName,
                c4: generation.referenceC4
            )]
            let chainData = Data(MHLWriter.chainXML(entries: nextEntries).utf8)
            var archiveURL: URL?
            if let previousChainData {
                let archiveDirectory = directory.appendingPathComponent("chain-history", isDirectory: true)
                try fileSystem.createDirectory(at: archiveDirectory)
                let archive = archiveDirectory.appendingPathComponent(
                    String(format: "ascmhl_chain_before_%04d.xml", sequence)
                )
                if !fileSystem.fileExists(at: archive) {
                    try writeExclusive(previousChainData, to: archive, fileSystem: fileSystem)
                }
                archiveURL = archive
                let staging = directory.appendingPathComponent(
                    ".doppelganger-partial-\(report.shortID)-ascmhl_chain.xml"
                )
                try writeExclusive(chainData, to: staging, fileSystem: fileSystem)
                try fileSystem.replaceGeneratedIndexAtomically(from: staging, to: chainURL)
            } else {
                try writeExclusive(chainData, to: chainURL, fileSystem: fileSystem)
            }
            return MHLWriteReceipt(
                destination: destination,
                directory: directory,
                generationURL: generationURL,
                chainURL: chainURL,
                previousChainData: previousChainData,
                archiveURL: archiveURL
            )
        } catch {
            try? fileSystem.removeItem(at: generationURL)
            throw error
        }
    }

    /// Repair only: pairs the parent verified at `destination` that this
    /// attempt does not list. Each copy must still be there at its verified
    /// size, the check a resume relies on; a folder that lost a verified copy
    /// gets no history that skips it or vouches for it from stale evidence.
    /// Only `parent` itself is read: a pair only an earlier attempt verified
    /// stays unlisted, which costs the folder its root hash, not its honesty.
    /// The digest comes from the parent's manifest on disk, so
    /// `MHLWriter.generation` refuses the generation unless it is well formed.
    private static func carriedRecords(
        from parent: TransferManifest?,
        report: TransferReport,
        destination: URL,
        fileSystem: any FileSystemAccess
    ) throws -> [MHLWriter.HashRecord] {
        guard let parent,
              parent.algorithm == report.algorithm.rawValue
                || (parent.algorithm == "xxh64" && report.algorithm == .xxh64)
        else { return [] }
        let listed = Set(report.items.map(\.item.relativePath))
        return try parent.items.compactMap { record in
            guard !listed.contains(record.relativePath),
                  let digest = record.digest,
                  record.results.contains(where: {
                      $0.destination == destination.path && $0.status == "verified"
                  })
            else { return nil }
            let copy = destination.appendingPathComponent(record.relativePath)
            guard let observed = try? fileSystem.sourceItem(at: copy, relativeTo: destination),
                  observed.size == record.size
            else { throw MHLHistoryError.carriedCopyChanged(path: record.relativePath) }
            return MHLWriter.HashRecord(
                relativePath: record.relativePath,
                size: record.size,
                modifiedAt: record.modifiedAt,
                digest: digest.lowercased(),
                hashDate: parent.finishedAt
            )
        }
    }

    static func rollback(_ receipt: MHLWriteReceipt, fileSystem: any FileSystemAccess) {
        try? fileSystem.removeItem(at: receipt.generationURL)
        if let previous = receipt.previousChainData {
            let staging = receipt.directory.appendingPathComponent(
                ".doppelganger-partial-rollback-ascmhl_chain.xml"
            )
            do {
                try writeExclusive(previous, to: staging, fileSystem: fileSystem)
                try fileSystem.replaceGeneratedIndexAtomically(from: staging, to: receipt.chainURL)
            } catch {
                try? fileSystem.removeItem(at: staging)
            }
        } else {
            try? fileSystem.removeItem(at: receipt.chainURL)
        }
    }

    /// Recovery after an interrupted finalization: the process appended a
    /// generation but never recorded a terminal verdict, so the generation
    /// vouches for a transfer nobody can prove finished. Removes it and puts
    /// the chain back to its archived predecessor (or removes the chain when
    /// this was the first generation).
    ///
    /// Guarded: acts only while the chain's last entry still names that
    /// generation file. Anything else — a later generation appended on top,
    /// a chain someone already restored, a missing chain — is left alone and
    /// reported as `false`.
    @discardableResult
    static func rollbackUncommitted(
        generationURL: URL,
        chainURL: URL,
        archiveURL: URL?,
        fileSystem: any FileSystemAccess
    ) -> Bool {
        guard fileSystem.fileExists(at: chainURL),
              let chainData = try? MHLReader.readAll(chainURL, fileSystem: fileSystem),
              let chain = try? MHLReader.readChain(chainData),
              chain.entries.last?.path == generationURL.lastPathComponent
        else { return false }
        let directory = chainURL.deletingLastPathComponent()

        if let archiveURL {
            guard fileSystem.fileExists(at: archiveURL),
                  let previous = try? MHLReader.readAll(archiveURL, fileSystem: fileSystem),
                  let previousChain = try? MHLReader.readChain(previous),
                  previousChain.entries.count == chain.entries.count - 1
            else { return false }
            let staging = directory.appendingPathComponent(
                ".doppelganger-partial-recovery-ascmhl_chain.xml"
            )
            do {
                if fileSystem.fileExists(at: staging) { try fileSystem.removeItem(at: staging) }
                try writeExclusive(previous, to: staging, fileSystem: fileSystem)
                try fileSystem.replaceGeneratedIndexAtomically(from: staging, to: chainURL)
            } catch {
                try? fileSystem.removeItem(at: staging)
                return false
            }
        } else {
            guard chain.entries.count == 1 else { return false }
            do {
                try fileSystem.removeItem(at: chainURL)
            } catch {
                return false
            }
        }
        // Chain no longer references the generation; only now is the
        // generation itself safe to drop.
        if fileSystem.fileExists(at: generationURL) {
            try? fileSystem.removeItem(at: generationURL)
        }
        return true
    }

    private static func writeExclusive(
        _ data: Data,
        to url: URL,
        fileSystem: any FileSystemAccess
    ) throws {
        let stream = try fileSystem.openForWritingExclusive(url)
        do {
            try stream.write(Array(data), count: data.count)
            try stream.close()
        } catch {
            try? fileSystem.removeItem(at: url)
            throw error
        }
    }
}

/// Why `MHLHistoryStore` refused to append a generation. The description is
/// English evidence text, like every other transfer issue.
enum MHLHistoryError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case conflictingHistory(path: String)
    case carriedCopyChanged(path: String)
    case malformedDigest(path: String)

    var description: String {
        switch self {
        case .conflictingHistory(let path):
            "the folder's ASC MHL history already records a different or incomparable hash for \(path); no contradicting generation was added"
        case .carriedCopyChanged(let path):
            "\(path) was verified by the parent attempt but is now missing or a different size, so the repair cannot record this folder's ASC MHL history"
        case .malformedDigest(let path):
            "the hash recorded for \(path) is not a well-formed digest in this transfer's checksum format, so the manifest it was read from may be damaged; no ASC MHL generation was added"
        }
    }

    var errorDescription: String? { description }
}
