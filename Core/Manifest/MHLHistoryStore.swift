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
    static func append(
        report: TransferReport,
        destination: URL,
        fileSystem: any FileSystemAccess
    ) throws -> MHLWriteReceipt? {
        guard report.status == .verified else { return nil }
        let directory = destination.appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
        try fileSystem.createDirectory(at: directory)
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        let previousChainData: Data?
        let priorEntries: [MHLWriter.ChainEntry]
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
                _ = try MHLReader.read(generationData)
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
        guard let generation = MHLWriter.generation(
            for: report,
            destination: destination,
            sequence: sequence,
            mediaVolumeIdentifier: try? fileSystem.volume(at: destination).identifier
        ) else { return nil }
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
