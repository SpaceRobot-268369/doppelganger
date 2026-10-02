import Foundation
import Observation

// MARK: - Source eject gate

/// What a verified attempt may offer for its source card, and why. Only
/// `.available` ever reaches an unmount.
enum SourceEjectEligibility: Equatable, Sendable {
    /// Not verified, not a removable whole-volume source, or no recorded volume.
    case notOffered
    /// The recorded volume has no UUID, so a same-named card mounted at the
    /// same path could not be told apart from it.
    case identityUnverifiable
    /// Nothing is mounted at the recorded mount point any more.
    case sourceGone
    /// Something is mounted at the recorded mount point, but not this card.
    case differentVolumeMounted
    /// Other queued or running transfers still use this volume.
    case inUse(count: Int)
    case available
}

/// One dashboard attempt's hold on storage, as the eject gate sees it.
struct SourceEjectClaim: Equatable, Sendable {
    let sessionID: UUID
    let isActive: Bool
    /// Volume identifiers of the attempt's source and destination bases.
    let volumeIdentifiers: Set<String>
    /// Canonical source and destination-base paths, which still match when
    /// a volume could not be resolved.
    let paths: [String]
}

enum SourceEjectOutcome: Equatable, Sendable {
    case ejected
    case refused(SourceEjectEligibility)
    case failed(String)

    var message: String {
        switch self {
        case .ejected:
            L10n.text("Source safely ejected.")
        case .failed(let reason):
            L10n.format("Could not eject source: %@", reason)
        case .refused(.sourceGone):
            L10n.text("Not ejected: the verified source is no longer mounted.")
        case .refused(.differentVolumeMounted):
            L10n.text("Not ejected: a different volume is now mounted where the verified source was.")
        case .refused(.inUse(let count)):
            count == 1
                ? L10n.text("Not ejected: another transfer still uses this source.")
                : L10n.format("Not ejected: %lld other transfers still use this source.", Int64(count))
        case .refused:
            L10n.text("Not ejected: Doppelganger could not confirm this is the verified source volume.")
        }
    }
}

/// The Eject Source decision as a pure function of snapshots.
enum SourceEjectGate {
    static func evaluate(
        sessionID: UUID,
        verdict: TransferStatus?,
        sourcePath: String,
        recorded: FileSystemVolume?,
        live: FileSystemVolume?,
        claims: [SourceEjectClaim]
    ) -> SourceEjectEligibility {
        guard verdict == .verified,
              let recorded,
              recorded.isRemovable,
              sourcePath == recorded.mountPath
        else { return .notOffered }
        guard hasStableIdentity(recorded) else { return .identityUnverifiable }
        // volume(at:) walks up from a mount point that no longer exists, so an
        // ejected or pulled card resolves to the parent volume and lands here.
        guard let live, live.mountPath == recorded.mountPath else { return .sourceGone }
        guard live.identifier == recorded.identifier,
              live.isRemovable,
              live.totalBytes == recorded.totalBytes
        else { return .differentVolumeMounted }
        let mountPrefix = recorded.mountPath + "/"
        let users = claims.filter { claim in
            claim.sessionID != sessionID && claim.isActive && (
                claim.volumeIdentifiers.contains(recorded.identifier)
                    || claim.paths.contains { $0 == recorded.mountPath || $0.hasPrefix(mountPrefix) }
            )
        }
        return users.isEmpty ? .available : .inUse(count: users.count)
    }

    /// Only a real volume UUID tells two same-named cards apart. RealFileSystem
    /// falls back to the mount path when a volume reports none.
    static func hasStableIdentity(_ volume: FileSystemVolume) -> Bool {
        UUID(uuidString: volume.identifier) != nil
    }

    /// Calls `eject` only for `.available`, and with the checked mount point.
    static func perform(
        _ eligibility: SourceEjectEligibility,
        mountPath: String?,
        eject: (URL) throws -> Void
    ) -> SourceEjectOutcome {
        guard eligibility == .available else { return .refused(eligibility) }
        guard let mountPath else { return .refused(.notOffered) }
        do {
            try eject(URL(fileURLWithPath: mountPath, isDirectory: true))
            return .ejected
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// One transfer, from launch to terminal report. Each session owns its own
/// engine instance, so several offloads can run side by side; the dashboard
/// lists sessions in creation order.
@MainActor
@Observable
final class TransferSession: Identifiable {
    let id: UUID
    let taskID: UUID
    let parentAttemptID: UUID?
    let attemptKind: TransferAttemptKind
    let label: String
    let source: URL
    let destinationBases: [URL]
    let destinations: [URL]
    let algorithm: ChecksumAlgorithm
    let verificationProfile: VerificationProfile
    let operatorProfile: OperatorProfile
    let projectID: UUID?
    let sourceFingerprint: String?
    let allowSameVolume: Bool
    let availableBytesByDestination: [URL: Int64]
    let createdAt: Date
    let sourceVolume: FileSystemVolume?
    let isRecovered: Bool
    private(set) var shortID = ""

    private(set) var progress = TransferProgress(phase: .enumerating)
    private(set) var planItemCount = 0
    private(set) var planTotalBytes: Int64 = 0
    private(set) var logEntries: [TransferLogEntry] = []
    /// Failures observed live during the run, newest last.
    private(set) var liveFailures: [(relativePath: String, destination: URL, reason: String)] = []
    private(set) var cancelRequested = false
    private(set) var pauseRequested = false
    private(set) var report: TransferReport?
    private(set) var lastLogFileURL: URL?
    private(set) var started = false
    private(set) var partialCleanupMessage: String?
    private(set) var contactSheetURL: URL?
    private(set) var contactSheetMessage: String?
    var showLog = false

    /// Fired once, on the main actor, when the terminal report arrives — the
    /// queue scheduler and notifier hang off this.
    var onFinished: (() -> Void)?
    var onStarted: (() -> Void)?

    private let engine: TransferEngine
    private var logStore: TransferLogStore?
    private var consumeTask: Task<Void, Never>?
    private var runStarted: Date?
    private let journalStore: TransferJournalStore
    private var journal: TransferJournal
    private let resumeManifest: TransferManifest?
    private let retryManifest: TransferManifest?
    /// The exact source items this attempt was asked to transfer, or `nil`
    /// for the whole source. A resume carries it forward unchanged.
    let includedRelativePaths: Set<String>?
    private let duplicateManifests: [String: TransferManifest]

    init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        parentAttemptID: UUID? = nil,
        attemptKind: TransferAttemptKind = .copy,
        label: String,
        source: URL,
        destinations: [TransferDestination],
        algorithm: ChecksumAlgorithm = .xxh3,
        verificationProfile: VerificationProfile = .standard,
        operatorProfile: OperatorProfile = OperatorProfile(displayName: "Local Operator"),
        projectID: UUID? = nil,
        sourceFingerprint: String? = nil,
        allowSameVolume: Bool = false,
        createdAt: Date = Date(),
        recoveredIssue: String? = nil,
        restoredReport: TransferReport? = nil,
        resumeManifest: TransferManifest? = nil,
        retryManifest: TransferManifest? = nil,
        includedRelativePaths: Set<String>? = nil,
        duplicateManifests: [String: TransferManifest] = [:],
        engine: TransferEngine? = nil
    ) {
        self.id = id
        self.taskID = taskID ?? id
        self.parentAttemptID = parentAttemptID
        self.attemptKind = attemptKind
        self.label = label
        self.source = source
        destinationBases = destinations.map(\.baseRoot)
        self.destinations = destinations.map(\.outputRoot)
        self.algorithm = algorithm
        self.verificationProfile = verificationProfile
        self.operatorProfile = operatorProfile
        self.projectID = projectID
        self.sourceFingerprint = sourceFingerprint
        self.allowSameVolume = allowSameVolume
        self.createdAt = createdAt
        self.resumeManifest = resumeManifest
        self.retryManifest = retryManifest
        self.includedRelativePaths = includedRelativePaths
        self.duplicateManifests = duplicateManifests
        isRecovered = recoveredIssue != nil
        let fileSystem = RealFileSystem()
        sourceVolume = try? fileSystem.volume(at: source)
        availableBytesByDestination = Dictionary(uniqueKeysWithValues: destinations.compactMap {
            guard let free = try? fileSystem.freeSpace(at: $0.baseRoot) else { return nil }
            return ($0.outputRoot, free)
        })
        self.engine = engine ?? TransferEngine(
            fileSystem: RealFileSystem(),
            sleepInhibitor: ProcessSleepInhibitor()
        )
        journalStore = TransferJournalStore(root: Self.spoolDirectory)
        journal = TransferJournal(
            id: id,
            taskID: self.taskID,
            parentAttemptID: parentAttemptID,
            attemptKind: attemptKind,
            label: label,
            source: source,
            destinationBases: destinations.map(\.baseRoot),
            destinations: destinations.map(\.outputRoot),
            algorithm: algorithm,
            verificationProfile: verificationProfile,
            operatorProfileID: operatorProfile.id,
            operatorDisplayName: operatorProfile.displayName,
            projectID: projectID,
            sourceFingerprint: sourceFingerprint,
            allowSameVolume: allowSameVolume,
            createdAt: createdAt,
            startedAt: nil,
            itemCount: 0,
            totalBytes: 0,
            status: .queued,
            includedRelativePaths: includedRelativePaths?.sorted()
        )

        if let restoredReport {
            // Offered again after relaunch: show the finished verdict and never
            // touch the journal, which still records it exactly.
            started = true
            shortID = restoredReport.shortID
            report = restoredReport
        } else if let recoveredIssue {
            started = true
            shortID = String(id.uuidString.prefix(8)).lowercased()
            planItemCount = journal.itemCount
            planTotalBytes = journal.totalBytes
            let possibleLocations = self.destinations + [
                Self.spoolDirectory.appendingPathComponent(shortID, isDirectory: true)
            ]
            let evidenceLocations = possibleLocations.filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(
                        ManifestWriter.manifestFileName(shortID: shortID)
                    ).path
                )
            }
            report = TransferReport(
                id: id,
                status: .failed,
                algorithm: algorithm,
                taskID: self.taskID,
                operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
                projectID: projectID,
                sourceFingerprint: sourceFingerprint,
                sourceRoot: source,
                destinations: self.destinations,
                startedAt: createdAt,
                finishedAt: Date(),
                items: [],
                manifestLocations: evidenceLocations,
                issues: [recoveredIssue]
            )
        } else {
            journalStore.save(journal)
        }
    }

    convenience init(
        interrupted journal: TransferJournal,
        issue: String = "The app exited before this transfer produced a terminal report. Treat every output as incomplete and keep the source media."
    ) {
        self.init(
            id: journal.id,
            taskID: journal.taskID,
            parentAttemptID: journal.parentAttemptID,
            attemptKind: journal.attemptKind ?? .copy,
            label: journal.label,
            source: journal.source,
            destinations: zip(journal.destinationBases, journal.destinations).map {
                TransferDestination(baseRoot: $0.0, outputRoot: $0.1)
            },
            algorithm: journal.algorithm,
            verificationProfile: journal.verificationProfile ?? .standard,
            operatorProfile: OperatorProfile(
                id: journal.operatorProfileID ?? UUID(),
                displayName: journal.operatorDisplayName ?? "Unknown Operator"
            ),
            projectID: journal.projectID,
            sourceFingerprint: journal.sourceFingerprint,
            allowSameVolume: journal.allowSameVolume,
            createdAt: journal.createdAt,
            recoveredIssue: issue,
            includedRelativePaths: journal.includedRelativePaths.map { Set($0) }
        )
        planItemCount = journal.itemCount
        planTotalBytes = journal.totalBytes
    }

    /// A paused or Fast-pending attempt offered again after relaunch.
    convenience init(restoring attempt: RestorableAttempt) {
        let journal = attempt.journal
        self.init(
            id: journal.id,
            taskID: journal.taskID,
            parentAttemptID: journal.parentAttemptID,
            attemptKind: journal.attemptKind ?? .copy,
            label: journal.label,
            source: journal.source,
            destinations: zip(journal.destinationBases, journal.destinations).map {
                TransferDestination(baseRoot: $0.0, outputRoot: $0.1)
            },
            algorithm: journal.algorithm,
            verificationProfile: journal.verificationProfile ?? .standard,
            operatorProfile: OperatorProfile(
                id: journal.operatorProfileID ?? UUID(),
                displayName: journal.operatorDisplayName ?? "Unknown Operator"
            ),
            projectID: journal.projectID,
            sourceFingerprint: journal.sourceFingerprint,
            allowSameVolume: journal.allowSameVolume,
            createdAt: journal.createdAt,
            restoredReport: attempt.report,
            includedRelativePaths: journal.includedRelativePaths.map { Set($0) }
        )
        planItemCount = journal.itemCount
        planTotalBytes = journal.totalBytes
    }

    /// Not yet terminal: queued or running.
    var isActive: Bool { report == nil }
    var isQueued: Bool { !started && report == nil }
    var isRunning: Bool { started && report == nil }
    var hasAttention: Bool {
        !liveFailures.isEmpty || (report.map { $0.status == .failed || $0.status == .cancelled } ?? false)
    }

    var failedPairCount: Int {
        guard let report else { return 0 }
        return report.items.reduce(0) { count, item in
            count + item.outcomes.values.reduce(0) { partial, outcome in
                if case .failed = outcome { return partial + 1 }
                return partial
            }
        }
    }

    var displayName: String { label }
    var sourceName: String { source.lastPathComponent.uppercased() }

    func baseDestination(for output: URL) -> URL {
        guard let index = destinations.firstIndex(of: output), destinationBases.indices.contains(index) else {
            return output
        }
        return destinationBases[index]
    }

    /// Queue resources are volume identifiers, not folder paths.
    var resourceIDs: Set<String> {
        let fileSystem = RealFileSystem()
        return Set(([source] + destinationBases).compactMap {
            try? fileSystem.volume(at: $0).identifier
        })
    }

    // MARK: - Lifecycle

    func start() {
        guard consumeTask == nil, report == nil else { return }
        started = true
        let request = TransferRequest(
            id: id,
            sourceRoot: source,
            destinations: zip(destinationBases, destinations).map {
                TransferDestination(baseRoot: $0.0, outputRoot: $0.1)
            },
            algorithm: algorithm,
            verificationProfile: verificationProfile,
            taskID: taskID,
            operatorSnapshot: OperatorSnapshot(profile: operatorProfile),
            projectID: projectID,
            sourceFingerprint: sourceFingerprint,
            spoolDirectory: Self.spoolDirectory,
            allowSameVolume: allowSameVolume,
            requireNewOutputRoots: resumeManifest == nil && retryManifest == nil && duplicateManifests.isEmpty,
            resumeManifest: resumeManifest,
            retryManifest: retryManifest,
            includedRelativePaths: includedRelativePaths,
            duplicateManifests: duplicateManifests
        )
        shortID = request.shortID
        let spoolTarget = Self.spoolDirectory.appendingPathComponent(request.shortID, isDirectory: true)
        let store = TransferLogStore(spoolTarget: spoolTarget, shortID: request.shortID)
        logStore = store
        lastLogFileURL = store.fileURL
        runStarted = Date()
        journal.startedAt = runStarted
        journal.status = .running
        journalStore.save(journal)
        onStarted?()

        consumeTask = Task { [weak self, engine] in
            let stream = await engine.run(request)
            for await event in stream {
                self?.handle(event)
            }
            self?.consumeTask = nil
        }
    }

    func cancel() {
        guard isActive else { return }
        cancelRequested = true
        Task { [engine] in
            await engine.cancel()
        }
    }

    func pause() {
        guard isRunning, !pauseRequested else { return }
        pauseRequested = true
        Task { [engine] in
            await engine.pause()
        }
    }

    func updateContactSheet(url: URL?, message: String) {
        contactSheetURL = url
        contactSheetMessage = message
    }

    private func handle(_ event: TransferEvent) {
        switch event {
        case .phaseChanged(let phase):
            progress.phase = phase
            if phase == .writingManifest {
                journal.status = .finalizing
                journalStore.save(journal)
            }
        case .planReady(let itemCount, let totalBytes):
            planItemCount = itemCount
            planTotalBytes = totalBytes
            journal.itemCount = itemCount
            journal.totalBytes = totalBytes
            journalStore.save(journal)
        case .progress(let snapshot):
            progress = snapshot
        case .itemOutcome(let relativePath, let destination, let outcome):
            if case .failed(let reason) = outcome {
                liveFailures.append((relativePath, destination, reason.slug))
            }
        case .log(let entry):
            logEntries.append(entry)
            logStore?.append(entry)
        case .finished(let finished):
            logStore?.close()
            logStore = nil
            report = finished
            // Paused and Fast-pending attempts are offered again after relaunch;
            // a linked attempt stopped before any destination releases its parent.
            journal.recordVerdict(of: finished)
            journalStore.save(journal)
            onFinished?()
        }
    }

    // MARK: - Derived progress

    /// Copy + verify are one budget: total work is plan bytes × (1 copy pass
    /// + one verify pass per destination).
    var overallFraction: Double {
        if let report {
            return report.status == .verified ? 1 : lastKnownFraction
        }
        return lastKnownFraction
    }

    private var lastKnownFraction: Double {
        let total = Double(planTotalBytes) * Double(workPassCount)
        guard total > 0 else { return 0 }
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        return min(done / total, 1)
    }

    var throughputBytesPerSecond: Double {
        guard isActive, let runStarted else { return 0 }
        let elapsed = Date().timeIntervalSince(runStarted)
        guard elapsed > 0.5 else { return 0 }
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        return done / elapsed
    }

    var etaSeconds: Double? {
        let rate = throughputBytesPerSecond
        guard rate > 0 else { return nil }
        let total = Double(planTotalBytes) * Double(workPassCount)
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        guard total > done else { return 0 }
        return (total - done) / rate
    }

    /// Bytes finished so far across copy + verify, for the "24.7 GB of 36.2 GB" line.
    var doneBytes: Int64 {
        progress.copiedBytes + progress.verifiedBytesByDestination.values.reduce(0, +)
    }

    var workBudgetBytes: Int64 {
        planTotalBytes * Int64(workPassCount)
    }

    private var workPassCount: Int {
        switch verificationProfile {
        case .fast: 1
        case .standard: 1 + max(destinations.count, 1)
        case .maximum: 2 + max(destinations.count, 1)
        }
    }

    func verifyFraction(for destination: URL) -> Double {
        guard planTotalBytes > 0 else { return 0 }
        let verified = progress.verifiedBytesByDestination[destination] ?? 0
        return min(Double(verified) / Double(planTotalBytes), 1)
    }

    // MARK: - Headline

    /// The status line under the card title — phase-specific while running,
    /// verdict once terminal. Copy completing is never presented as success.
    var headline: (text: String, isProblem: Bool) {
        if isQueued { return ("Queued · waiting for a slot", false) }
        if let report {
            switch report.status {
            case .paused: return ("Paused safely · Resume available", false)
            case .transferredPendingVerification:
                return ("Transferred · verification pending", false)
            case .verified: return ("Verified · Complete", false)
            case .failed:
                if isRecovered { return ("Interrupted · Review required", true) }
                if report.failedCount > 0 {
                    return ("Failed · \(report.failedCount) copy result\(report.failedCount == 1 ? "" : "s") failed", true)
                }
                return ("Failed · transfer evidence incomplete", true)
            case .cancelled: return ("Cancelled · Incomplete", true)
            }
        }
        let percent = Int(overallFraction * 100)
        switch progress.phase {
        case .enumerating: return ("Scanning source…", false)
        case .preReadingSource: return ("Maximum · reading source…", false)
        case .copying: return ("Copying · \(percent)%", false)
        case .verifying: return ("Verifying · \(percent)%", false)
        case .writingManifest: return ("Writing manifest…", false)
        case .done: return ("Finishing…", false)
        }
    }

    // MARK: - Per-destination presentation

    enum DestinationState {
        case pending
        case copying
        case verifying
        case pendingVerification
        case paused
        case verified
        case failed
    }

    func destinationState(_ destination: URL) -> DestinationState {
        if let report {
            if report.status == .paused { return .paused }
            let failures = report.items.filter {
                if case .failed = $0.outcomes[destination] { return true } else { return false }
            }.count
            let verified = report.items.filter { $0.outcomes[destination]?.isVerified == true }.count
            if failures > 0 { return .failed }
            let pending = report.items.filter {
                $0.outcomes[destination]?.isTransferredPendingVerification == true
            }.count
            if pending == report.items.count && !report.items.isEmpty { return .pendingVerification }
            return verified == report.items.count && !report.items.isEmpty ? .verified : .failed
        }
        switch progress.phase {
        case .enumerating, .preReadingSource: return .pending
        case .copying: return .copying
        default: return .verifying
        }
    }

    func destinationFraction(_ destination: URL) -> Double {
        if let report {
            guard planTotalBytes > 0 || !report.items.isEmpty else { return 0 }
            let total = report.items.reduce(Int64(0)) { $0 + $1.item.size }
            guard total > 0 else { return 0 }
            let verified = report.items.reduce(Int64(0)) { value, item in
                value + (item.outcomes[destination]?.isVerified == true ? item.item.size : 0)
            }
            return min(Double(verified) / Double(total), 1)
        }
        switch progress.phase {
        case .enumerating:
            return 0
        case .copying:
            guard planTotalBytes > 0 else { return 0 }
            return min(
                Double(progress.copiedBytesByDestination[destination] ?? 0) / Double(planTotalBytes),
                1
            )
        default:
            return verifyFraction(for: destination)
        }
    }

    func destinationThroughput(_ destination: URL) -> Double {
        guard isRunning, let runStarted else { return 0 }
        let elapsed = Date().timeIntervalSince(runStarted)
        guard elapsed > 0.5 else { return 0 }
        let bytes = (progress.copiedBytesByDestination[destination] ?? 0)
            + (progress.verifiedBytesByDestination[destination] ?? 0)
        return Double(bytes) / elapsed
    }

    func destinationETA(_ destination: URL) -> Double? {
        let rate = destinationThroughput(destination)
        guard rate > 0 else { return nil }
        let passes: Int64 = verificationProfile == .fast ? 1 : 2
        let total = planTotalBytes * passes
        let done = (progress.copiedBytesByDestination[destination] ?? 0)
            + (progress.verifiedBytesByDestination[destination] ?? 0)
        return max(Double(total - done) / rate, 0)
    }

    func isBottleneck(_ destination: URL) -> Bool {
        guard isRunning, destinations.count > 1 else { return false }
        let rates = destinations.map { ($0, destinationThroughput($0)) }.filter { $0.1 > 0 }
        guard rates.count > 1, let slowest = rates.min(by: { $0.1 < $1.1 }) else { return false }
        return slowest.0 == destination
    }

    func destinationErrorCount(_ destination: URL) -> Int {
        if let report {
            return report.items.filter {
                if case .failed = $0.outcomes[destination] { return true } else { return false }
            }.count
        }
        return liveFailures.filter { $0.destination == destination }.count
    }

    func destinationStatusText(_ destination: URL) -> String {
        let errors = destinationErrorCount(destination)
        let errorText = L10n.format("%lld errors", Int64(errors))
        switch destinationState(destination) {
        case .pending: return L10n.text("Waiting")
        case .copying: return L10n.format("Copying · %@", errorText)
        case .verifying: return L10n.format("Verifying · %@", errorText)
        case .pendingVerification: return L10n.text("Transferred · verification pending")
        case .paused: return L10n.text("Paused · completed files retained")
        case .verified: return L10n.format("Verified · %@", errorText)
        case .failed:
            return errors > 0 ? L10n.format("Failed · %@", errorText) : L10n.text("Incomplete")
        }
    }

    // MARK: - Generated files

    var markdownReportURL: URL? {
        guard let report, let location = report.manifestLocations.first else { return nil }
        return location.appendingPathComponent(ManifestWriter.reportFileName(shortID: report.shortID))
    }

    var manifestURL: URL? {
        guard let report, let location = report.manifestLocations.first else { return nil }
        return location.appendingPathComponent(ManifestWriter.manifestFileName(shortID: report.shortID))
    }

    /// The first destination that actually received an MHL (only destinations
    /// with at least one verified item get one).
    var mhlURL: URL? {
        guard let report else { return nil }
        for destination in report.destinations {
            let chain = destination
                .appendingPathComponent(MHLWriter.directoryName, isDirectory: true)
                .appendingPathComponent(MHLWriter.chainFileName)
            if FileManager.default.fileExists(atPath: chain.path) { return chain }
            let legacy = destination.appendingPathComponent(MHLWriter.fileName(shortID: report.shortID))
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return nil
    }

    // MARK: - Source eject

    /// What the action row may offer for this attempt's source card. It runs
    /// on every render of a verified card, so it reads only what is already
    /// known: the volume watcher's list for the card mounted now, and what
    /// each other attempt recorded at creation for the claims. Reading
    /// `mounted` re-renders the card on every mount change, and a mount point
    /// the watcher no longer lists counts as gone. `ejectSource` re-reads
    /// everything before it unmounts.
    func sourceEjectEligibility(
        among sessions: [TransferSession],
        mounted: [MountedVolume]
    ) -> SourceEjectEligibility {
        guard report?.status == .verified else { return .notOffered }
        return evaluateSourceEject(
            live: Self.watchedVolume(at: sourceVolume?.mountPath, among: mounted),
            claims: sessions.filter { $0.id != id && $0.isActive }.map(\.recordedEjectClaim)
        )
    }

    /// Re-reads the card at the recorded mount point and every other active
    /// attempt's volumes, re-runs every check, and unmounts only when all of
    /// them pass. Nothing suspends between the last check and `eject`.
    func ejectSource(
        among sessions: [TransferSession],
        mounted: [MountedVolume],
        eject: (URL) throws -> Void
    ) -> SourceEjectOutcome {
        let eligibility: SourceEjectEligibility = report?.status == .verified
            ? evaluateSourceEject(
                live: liveSourceVolume(mounted: mounted, fileSystem: RealFileSystem()),
                claims: sessions.filter { $0.id != id && $0.isActive }.map(\.sourceEjectClaim)
            )
            : .notOffered
        return SourceEjectGate.perform(eligibility, mountPath: sourceVolume?.mountPath, eject: eject)
    }

    private func evaluateSourceEject(
        live: FileSystemVolume?,
        claims: [SourceEjectClaim]
    ) -> SourceEjectEligibility {
        SourceEjectGate.evaluate(
            sessionID: id,
            verdict: report?.status,
            sourcePath: RealFileSystem().canonicalURL(source).path,
            recorded: sourceVolume,
            live: live,
            claims: claims
        )
    }

    /// The storage this attempt holds while it is queued or running, re-read
    /// now: every volume it touches and its resolved paths.
    var sourceEjectClaim: SourceEjectClaim {
        let fileSystem = RealFileSystem()
        return SourceEjectClaim(
            sessionID: id,
            isActive: isActive,
            volumeIdentifiers: resourceIDs.union(sourceVolume.map { [$0.identifier] } ?? []),
            paths: ([source] + destinationBases).map { fileSystem.canonicalURL($0).path }
        )
    }

    /// The same hold from what the attempt recorded at creation: its source
    /// volume, and its paths standardized but not resolved. Cheap enough for
    /// every render; a destination reached through another path is caught by
    /// `sourceEjectClaim` at click time.
    private var recordedEjectClaim: SourceEjectClaim {
        SourceEjectClaim(
            sessionID: id,
            isActive: isActive,
            volumeIdentifiers: sourceVolume.map { [$0.identifier] } ?? [],
            paths: ([source] + destinationBases).map(\.standardizedFileURL.path)
        )
    }

    /// The volume mounted at the recorded source mount point, re-read now.
    private func liveSourceVolume(
        mounted: [MountedVolume],
        fileSystem: RealFileSystem
    ) -> FileSystemVolume? {
        guard let mountPath = sourceVolume?.mountPath,
              mounted.contains(where: { $0.url.standardizedFileURL.path == mountPath })
        else { return nil }
        return try? fileSystem.volume(at: URL(fileURLWithPath: mountPath, isDirectory: true))
    }

    /// The volume the watcher lists at `mountPath`, in the shape the gate
    /// compares. Its identity is the volume UUID, or the mount path when it
    /// reports none, as `RealFileSystem` falls back; an unreported capacity
    /// stays unknown rather than reading as zero.
    nonisolated static func watchedVolume(at mountPath: String?, among mounted: [MountedVolume]) -> FileSystemVolume? {
        guard let mountPath,
              let volume = mounted.first(where: { $0.url.standardizedFileURL.path == mountPath })
        else { return nil }
        return FileSystemVolume(
            identifier: volume.volumeIdentifier ?? mountPath,
            name: volume.name,
            mountPath: mountPath,
            totalBytes: volume.totalBytes > 0 ? volume.totalBytes : nil,
            isRemovable: volume.isRemovable
        )
    }

    /// Removes only hidden staging files generated by this transfer ID. Final
    /// output names, manifests, logs, and source media are never candidates.
    func cleanupGeneratedPartials() {
        guard report != nil else { return }
        let prefix = ".doppelganger-partial-\(shortID)-"
        var removed = 0
        var failures = 0
        for destination in destinations {
            guard let enumerator = FileManager.default.enumerator(
                at: destination,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(prefix) {
                do {
                    try FileManager.default.removeItem(at: url)
                    removed += 1
                } catch {
                    failures += 1
                }
            }
        }
        partialCleanupMessage = failures == 0
            ? L10n.format("Removed %lld temporary files.", Int64(removed))
            : L10n.format(
                "Removed %lld temporary files; %lld could not be removed.",
                Int64(removed), Int64(failures)
            )
    }

    static var spoolDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
    }
}
