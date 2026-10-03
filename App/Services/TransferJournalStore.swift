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
    /// `true` when the attempt ended paused or Fast-pending, the only
    /// verdicts with a next step on their card, so the dashboard offers it
    /// again after relaunch; `false` once the operator removes the card.
    /// `nil` on every other journal, including all written before this key
    /// existed, which are therefore never resurrected.
    var offeredAtLaunch: Bool? = nil
    /// `true` when the engine stopped the attempt before it reached any
    /// destination (`TransferReport.neverReachedDestinations`). A resume or
    /// repair like that never took its parent's destinations over, so the
    /// parent keeps its Resume or Retry. `nil` otherwise, including a run
    /// interrupted mid-way, which may have written before it stopped.
    var neverReachedDestinations: Bool? = nil
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
    /// The exact source items the attempt was asked to transfer, sorted;
    /// `nil` for the whole source. Optional so journals written before this
    /// key existed still decode, as whole-source attempts.
    var includedRelativePaths: [String]? = nil
    /// ASC MHL generations this run appended, recorded so an interrupted
    /// finalization can be rolled back; generation filenames alone do not
    /// carry the transfer id. Optional so journals written before this key
    /// existed still decode (synthesized Codable ignores property defaults).
    var mhlGenerations: [MHLGenerationRecord]? = nil
}

struct MHLGenerationRecord: Codable, Sendable, Equatable {
    let destination: URL
    let generationURL: URL
    let chainURL: URL
    let archiveURL: URL?
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

    // MARK: - Offered again at launch

    /// Paused and Fast-pending attempts to show again at this launch, oldest
    /// first. Read-only: no journal, manifest, report or media is written,
    /// moved or removed. An attempt a linked resume or repair carries on is
    /// that child's to show, so it is not offered.
    func launchOffers() -> [LaunchOffer] {
        let journals = loadAll()
        let continued = Self.continuedParents(in: journals)
        return journals
            .filter { $0.offeredAtLaunch == true && !continued.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { restorable($0).map(LaunchOffer.restorable) ?? .unreadable($0) }
    }

    /// What the next launch would do with each of these attempts as things
    /// stand now, by exactly the rules `launchOffers()` applies. The quit
    /// warning asks; this only reads.
    func launchFates(of ids: [UUID]) -> [UUID: LaunchFate] {
        let journals = loadAll()
        let continued = Self.continuedParents(in: journals)
        let byID = Dictionary(journals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(ids.map { id -> (UUID, LaunchFate) in
            if continued.contains(id) { return (id, .continued) }
            return (id, byID[id].flatMap(restorable) == nil ? .lost : .offered)
        }, uniquingKeysWith: { first, _ in first })
    }

    /// The operator removed this attempt's card. The journal stays as
    /// history; only the offer ends.
    func stopOffering(_ id: UUID) {
        guard var journal = load(id), journal.offeredAtLaunch == true else { return }
        journal.offeredAtLaunch = false
        save(journal)
    }

    /// Rebuilds the finished report from the run's own spool manifest, which
    /// the engine always writes before a paused or pending verdict reaches
    /// the journal. Every identifying field must match the journal and every
    /// pair must be one such a run can record; otherwise `nil`, and the
    /// caller fails closed.
    private func restorable(_ journal: TransferJournal) -> RestorableAttempt? {
        let status: TransferStatus
        switch journal.status {
        case .paused: status = .paused
        case .transferredPendingVerification: status = .transferredPendingVerification
        default: return nil
        }
        let shortID = shortID(for: journal.id)
        let name = ManifestWriter.manifestFileName(shortID: shortID)
        let spoolTarget = root.appendingPathComponent(shortID, isDirectory: true)
        guard journal.offeredAtLaunch == true,
              journal.destinationBases.count == journal.destinations.count,
              let data = try? Data(contentsOf: spoolTarget.appendingPathComponent(name)),
              let manifest = try? ManifestWriter.decode(data),
              manifest.transferID == journal.id.uuidString.lowercased(),
              manifest.taskID == (journal.taskID ?? journal.id).uuidString.lowercased(),
              manifest.status == status.rawValue,
              manifest.algorithm == journal.algorithm.rawValue,
              manifest.verificationProfile == journal.verificationProfile?.rawValue,
              manifest.sourceFingerprint == journal.sourceFingerprint,
              manifest.sourceRoot == journal.source.path,
              manifest.destinations.map(\.path) == journal.destinations.map(\.path),
              let items = Self.items(in: manifest, destinations: journal.destinations)
        else { return nil }
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return RestorableAttempt(journal: journal, report: TransferReport(
            id: journal.id,
            status: status,
            algorithm: journal.algorithm,
            verificationProfile: journal.verificationProfile ?? .standard,
            taskID: journal.taskID,
            operatorSnapshot: journal.operatorProfileID.map {
                OperatorSnapshot(profileID: $0, displayName: journal.operatorDisplayName ?? "Unknown Operator")
            },
            projectID: journal.projectID,
            sourceFingerprint: journal.sourceFingerprint,
            sourceRoot: journal.source,
            destinations: journal.destinations,
            startedAt: (try? Date(manifest.startedAt, strategy: iso)) ?? journal.startedAt ?? journal.createdAt,
            finishedAt: (try? Date(manifest.finishedAt, strategy: iso)) ?? journal.createdAt,
            items: items,
            // The checked spool copy first: Resume and Verify read exactly the
            // record validated here. Destination copies follow for Reveal.
            manifestLocations: [spoolTarget] + journal.destinations.filter {
                fileManager.fileExists(atPath: $0.appendingPathComponent(name).path)
            },
            issues: manifest.issues ?? []
        ))
    }

    /// A paused or Fast-pending run records no failure: each pair is verified,
    /// transferred pending verification, or skipped with a reason. Anything
    /// else, or a destination the journal does not name, refuses.
    private static func items(in manifest: TransferManifest, destinations: [URL]) -> [ItemResult]? {
        let byPath = Dictionary(destinations.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [ItemResult] = []
        for record in manifest.items {
            var outcomes: [URL: ItemDestinationOutcome] = [:]
            for result in record.results {
                guard let destination = byPath[result.destination] else { return nil }
                switch result.status {
                case "verified":
                    outcomes[destination] = result.reason == "verified-duplicate-skip" ? .verifiedDuplicate : .verified
                case "transferred-pending-verification":
                    outcomes[destination] = .transferredPendingVerification
                case "skipped":
                    guard let reason = result.reason.flatMap(ItemSkipReason.init(rawValue:)) else { return nil }
                    outcomes[destination] = .skipped(reason)
                default:
                    return nil
                }
            }
            items.append(ItemResult(
                item: SourceItem(relativePath: record.relativePath, size: record.size),
                sourceDigest: record.digest,
                outcomes: outcomes
            ))
        }
        return items
    }

    /// One attempt's journal, while the spool still holds it.
    func load(_ id: UUID) -> TransferJournal? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TransferJournal.self, from: data)
    }

    /// Resume and repair attempts that took their parent's destinations over,
    /// from any launch. One created but never started (withdrawn, or still
    /// queued at quit), or one the engine stopped before any destination,
    /// wrote nothing there and is left out.
    func startedContinuations() -> [TransferJournal] {
        loadAll().filter(Self.continuesParent)
    }

    /// A resume or repair that started carries its parent on unless the
    /// engine stopped it before it reached any destination. One interrupted
    /// mid-run counts: it may have written before it stopped.
    private static func continuesParent(_ journal: TransferJournal) -> Bool {
        journal.parentAttemptID != nil
            && journal.startedAt != nil
            && (journal.attemptKind == .resume || journal.attemptKind == .retry)
            && journal.neverReachedDestinations != true
    }

    private static func continuedParents(in journals: [TransferJournal]) -> Set<UUID> {
        Set(journals.filter(continuesParent).compactMap(\.parentAttemptID))
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
        // The engine only reports generations once every destination's
        // append succeeded, so each one here was fully written; what never
        // happened is the terminal verdict that would justify keeping it.
        let fileSystem = RealFileSystem()
        for generation in journal.mhlGenerations ?? [] {
            MHLHistoryStore.rollbackUncommitted(
                generationURL: generation.generationURL,
                chainURL: generation.chainURL,
                archiveURL: generation.archiveURL,
                fileSystem: fileSystem
            )
        }
    }
}

extension TransferJournal {
    /// Records the engine's terminal verdict. Paused and Fast-pending are the
    /// only verdicts with a next step on their card (Resume, Verify), so only
    /// they are offered again after relaunch.
    mutating func recordVerdict(_ verdict: TransferStatus) {
        status = switch verdict {
        case .paused: .paused
        case .transferredPendingVerification: .transferredPendingVerification
        case .verified: .verified
        case .failed: .failed
        case .cancelled: .cancelled
        }
        offeredAtLaunch = verdict == .paused || verdict == .transferredPendingVerification ? true : nil
    }

    /// Records the engine's terminal report: its verdict, and whether the
    /// engine stopped the attempt before it reached any destination.
    mutating func recordVerdict(of report: TransferReport) {
        recordVerdict(report.status)
        neverReachedDestinations = report.neverReachedDestinations ? true : nil
    }
}

extension TransferReport {
    /// The engine stopped this attempt at a gate that runs before any
    /// destination is touched (a changed source plan, missing selected items,
    /// a source it could not read): it ended failed or cancelled without a
    /// single file/destination outcome. Once destinations are prepared, every
    /// pair is given an outcome before the run ends, even one the run never
    /// reached, so a report without any wrote nothing at a destination beyond,
    /// at most, its own record of the refusal. Only an engine's terminal
    /// report says this; a recovered card's placeholder has no items either.
    var neverReachedDestinations: Bool {
        (status == .failed || status == .cancelled)
            && items.allSatisfy { $0.outcomes.isEmpty }
    }
}

/// A paused or Fast-pending attempt shown again after relaunch, its report
/// rebuilt from its own checked spool manifest.
struct RestorableAttempt: Sendable {
    let journal: TransferJournal
    let report: TransferReport
}

/// What one offered journal becomes at launch.
enum LaunchOffer: Sendable {
    /// Its record checks out: the card returns with Resume, or as pending.
    case restorable(RestorableAttempt)
    /// Offered, but its record is missing or does not match. It returns as a
    /// card that needs review and can never be resumed: never silent.
    case unreadable(TransferJournal)
}

/// What the next launch does with a paused or Fast-pending attempt.
enum LaunchFate: Equatable, Sendable {
    /// Its card comes back with its next step.
    case offered
    /// A linked attempt that took its destinations over carries it on, so
    /// its own card does not come back and nothing is lost.
    case continued
    /// Neither: quitting now loses its card.
    case lost
}
