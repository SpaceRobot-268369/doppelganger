import Foundation

/// Small durable state written before a transfer starts. Manifests prove a
/// completed run; journals make an interrupted run visible after relaunch.
struct TransferJournal: Codable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case queued
        case running
        case finalizing
        case paused
        case transferredPendingVerification
        case verified
        case failed
        case cancelled
        case interrupted

        var isUnfinished: Bool { self == .queued || self == .running || self == .finalizing }
    }

    let id: UUID
    var taskID: UUID? = nil
    var parentAttemptID: UUID? = nil
    var attemptKind: TransferAttemptKind? = nil
    let label: String
    let source: URL
    let destinationBases: [URL]
    let destinations: [URL]
    let algorithm: ChecksumAlgorithm
    var verificationProfile: VerificationProfile? = nil
    var operatorProfileID: UUID? = nil
    var operatorDisplayName: String? = nil
    var projectID: UUID? = nil
    var sourceFingerprint: String? = nil
    let allowSameVolume: Bool
    let createdAt: Date
    var startedAt: Date?
    var itemCount: Int
    var totalBytes: Int64
    var status: Status
}

/// Journals live beside the transfer log and evidence spool. Writes are
/// atomic, so a power loss leaves either the previous valid record or the new
/// one, never a half-written JSON document.
struct TransferJournalStore {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    func save(_ journal: TransferJournal) {
        let directory = root.appendingPathComponent(shortID(for: journal.id), isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(journal).write(to: fileURL(for: journal.id), options: .atomic)
        } catch {
            // Journal failure must not claim the media transfer failed. The
            // engine's reports remain authoritative; this file only restores
            // interrupted UI state.
        }
    }

    /// Returns unfinished records and immediately marks them interrupted, so
    /// the same stale task is not rediscovered on every launch.
    func recoverInterrupted() -> [TransferJournal] {
        let unfinished = loadAll().filter(\.status.isUnfinished)
        for var journal in unfinished {
            removeUncommittedEvidence(for: journal)
            journal.status = .interrupted
            save(journal)
        }
        return unfinished.sorted { $0.createdAt < $1.createdAt }
    }

    private func loadAll() -> [TransferJournal] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return directories.compactMap { directory in
            let url = directory.appendingPathComponent("transfer-journal.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(TransferJournal.self, from: data)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        root
            .appendingPathComponent(shortID(for: id), isDirectory: true)
            .appendingPathComponent("transfer-journal.json")
    }

    private func shortID(for id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// A process can stop between publishing evidence to different volumes.
    /// Until the journal reaches a terminal state, remove only this run's
    /// uniquely named evidence so a stray VERIFIED record cannot outlive an
    /// interrupted multi-destination finalization. Copied media is untouched.
    private func removeUncommittedEvidence(for journal: TransferJournal) {
        let shortID = shortID(for: journal.id)
        let spoolTarget = root.appendingPathComponent(shortID, isDirectory: true)
        for location in journal.destinations + [spoolTarget] {
            for name in [
                ManifestWriter.manifestFileName(shortID: shortID),
                ManifestWriter.reportFileName(shortID: shortID),
                MHLWriter.fileName(shortID: shortID),
            ] {
                let url = location.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }
}
