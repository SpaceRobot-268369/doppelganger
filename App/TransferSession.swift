import Foundation
import Observation

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
    /// Free bytes per output root, measured on the destination's base volume.
    /// Captured at creation, then refreshed on a coarse heartbeat while the
    /// transfer runs — see `ensureFreeSpaceRefresh()`.
    private(set) var availableBytesByDestination: [URL: Int64]
    let createdAt: Date
    let sourceVolume: FileSystemVolume?
    let isRecovered: Bool
    private(set) var shortID = ""

    private(set) var progress = TransferProgress(phase: .enumerating) {
        didSet {
            recordThroughputSample()
            ensureFreeSpaceRefresh()
        }
    }
    private(set) var planItemCount = 0
    private(set) var planTotalBytes: Int64 = 0
    private(set) var logEntries: [TransferLogEntry] = []
    /// Failures observed live during the run, newest last.
    private(set) var liveFailures: [(relativePath: String, destination: URL, reason: String)] = []
    private(set) var cancelRequested = false
    private(set) var pauseRequested = false
    private(set) var report: TransferReport? {
        didSet { if report != nil { stopFreeSpaceRefresh() } }
    }
    private(set) var lastLogFileURL: URL?
    private(set) var started = false
    private(set) var partialCleanupMessage: String?
    private(set) var contactSheetURL: URL?
    private(set) var contactSheetMessage: String?
    var showLog = false
    /// Presentation only, never persisted or journaled. True while a linked
    /// resume or repair attempt has taken this attempt's destinations over:
    /// the operator carries on from that attempt's card, so this one must no
    /// longer promise Resume. The attempt-lifecycle owner sets it when a
    /// resume/repair child claims this attempt as its parent, and clears it
    /// when that claim is released; nothing else writes it.
    var continuedInLinkedAttempt = false

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
    private let includedRelativePaths: Set<String>?
    private let duplicateManifests: [String: TransferManifest]

    /// Recent (time, bytes) samples for the sliding-window rate — overall and
    /// per destination. Presentation-only; never persisted.
    private var throughputSamples: [ThroughputSample] = []
    private var destinationThroughputSamples: [URL: [ThroughputSample]] = [:]
    private var freeSpaceTask: Task<Void, Never>?

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
            status: .queued
        )

        if let recoveredIssue {
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

    convenience init(interrupted journal: TransferJournal) {
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
            recoveredIssue: "The app exited before this transfer produced a terminal report. Treat every output as incomplete and keep the source media."
        )
        planItemCount = journal.itemCount
        planTotalBytes = journal.totalBytes
    }

    /// Not yet terminal: queued or running.
    var isActive: Bool { report == nil }
    var isQueued: Bool { !started && report == nil }
    var isRunning: Bool { started && report == nil }

    /// The one definition of "needs attention" the dashboard, the filter chip,
    /// and the sidebar footer all share: a live failure, a failed or cancelled
    /// verdict, or a Fast-profile copy whose source still cannot be erased.
    /// Paused is deliberate — it has its own Resume action — so it is not
    /// attention.
    var needsAttention: Bool {
        Self.needsAttention(liveFailureCount: liveFailures.count, status: report?.status)
    }

    nonisolated static func needsAttention(liveFailureCount: Int, status: TransferStatus?) -> Bool {
        if liveFailureCount > 0 { return true }
        switch status {
        case .failed, .cancelled, .transferredPendingVerification: return true
        case .paused, .verified, nil: return false
        }
    }

    @available(*, deprecated, renamed: "needsAttention")
    var hasAttention: Bool { needsAttention }

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
            journal.status = switch finished.status {
            case .paused: .paused
            case .transferredPendingVerification: .transferredPendingVerification
            case .verified: .verified
            case .failed: .failed
            case .cancelled: .cancelled
            }
            journalStore.save(journal)
            onFinished?()
        }
    }

    // MARK: - Derived progress

    /// Copy + verify are one budget: total work is plan bytes × (1 copy pass
    /// + one verify pass per destination).
    var overallFraction: Double {
        if let report {
            // Both terminal "all bytes landed" verdicts are 100% of the work
            // this profile promised; the colour, not the number, says whether
            // that is verified (green) or still pending read-back (yellow).
            switch report.status {
            case .verified, .transferredPendingVerification: return 1
            case .failed, .cancelled, .paused: return lastKnownFraction
            }
        }
        return lastKnownFraction
    }

    private var lastKnownFraction: Double {
        let total = Double(planTotalBytes) * Double(workPassCount)
        guard total > 0 else { return 0 }
        return min(Double(doneBytes) / total, 1)
    }

    /// Rate over the last `ThroughputWindow.duration` seconds of progress
    /// samples, falling back to the cumulative rate until two samples exist.
    var throughputBytesPerSecond: Double {
        guard isActive, let runStarted else { return 0 }
        let now = Date()
        if let windowed = ThroughputWindow.rate(
            samples: throughputSamples,
            now: now.timeIntervalSinceReferenceDate
        ) {
            return windowed
        }
        let elapsed = now.timeIntervalSince(runStarted)
        guard elapsed > 0.5 else { return 0 }
        return Double(doneBytes) / elapsed
    }

    var etaSeconds: Double? {
        let rate = throughputBytesPerSecond
        guard rate > 0 else { return nil }
        let total = Double(planTotalBytes) * Double(workPassCount)
        let done = Double(doneBytes)
        guard total > done else { return 0 }
        return (total - done) / rate
    }

    // MARK: - Throughput sampling

    /// Appends one (time, bytes) sample overall and per destination whenever
    /// a progress snapshot lands, keeping only what the window needs.
    private func recordThroughputSample() {
        let now = Date().timeIntervalSinceReferenceDate
        throughputSamples = ThroughputWindow.appending(
            ThroughputSample(time: now, bytes: doneBytes),
            to: throughputSamples,
            now: now
        )
        for destination in destinations {
            destinationThroughputSamples[destination] = ThroughputWindow.appending(
                ThroughputSample(time: now, bytes: destinationDoneBytes(destination)),
                to: destinationThroughputSamples[destination] ?? [],
                now: now
            )
        }
    }

    private func destinationDoneBytes(_ destination: URL) -> Int64 {
        (progress.copiedBytesByDestination[destination] ?? 0)
            + (progress.verifiedBytesByDestination[destination] ?? 0)
    }

    // MARK: - Live free space

    /// Starts one coarse heartbeat that re-reads each destination volume's
    /// free space off the main actor while the transfer runs. The heartbeat
    /// ends by itself once a terminal report lands.
    private func ensureFreeSpaceRefresh() {
        guard freeSpaceTask == nil, isRunning else { return }
        let pairs = Array(zip(destinations, destinationBases))
        freeSpaceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.freeSpaceRefreshInterval))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                let fresh = await Self.measureFreeSpace(pairs)
                guard !Task.isCancelled, self.isRunning else { return }
                self.availableBytesByDestination = fresh
            }
        }
    }

    private func stopFreeSpaceRefresh() {
        freeSpaceTask?.cancel()
        freeSpaceTask = nil
    }

    private static let freeSpaceRefreshInterval: Double = 5

    /// Runs on the generic executor, never the main actor: volume metadata
    /// reads can stall on a slow or sleeping external drive.
    private nonisolated static func measureFreeSpace(_ pairs: [(URL, URL)]) async -> [URL: Int64] {
        let fileSystem = RealFileSystem()
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { output, base in
            guard let free = try? fileSystem.freeSpace(at: base) else { return nil }
            return (output, free)
        })
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
        if isQueued { return (L10n.text("Queued · waiting for a slot"), false) }
        if let report {
            switch report.status {
            case .paused:
                return (Self.pausedHeadline(continuedInLinkedAttempt: continuedInLinkedAttempt), false)
            case .transferredPendingVerification:
                return (L10n.text("Transferred · verification pending"), false)
            case .verified: return (L10n.text("Verified · Complete"), false)
            case .failed:
                if isRecovered { return (L10n.text("Interrupted · Review required"), true) }
                if report.failedCount == 1 {
                    return (L10n.text("Failed · 1 copy result failed"), true)
                }
                if report.failedCount > 1 {
                    return (L10n.format("Failed · %lld copy results failed", Int64(report.failedCount)), true)
                }
                return (L10n.text("Failed · transfer evidence incomplete"), true)
            case .cancelled: return (L10n.text("Cancelled · Incomplete"), true)
            }
        }
        let percent = Int64(overallFraction * 100)
        switch progress.phase {
        case .enumerating: return (L10n.text("Scanning source…"), false)
        case .preReadingSource: return (L10n.text("Maximum · reading source…"), false)
        case .copying: return (L10n.format("Copying · %lld%%", percent), false)
        case .verifying: return (L10n.format("Verifying · %lld%%", percent), false)
        case .writingManifest: return (L10n.text("Writing manifest…"), false)
        case .done: return (L10n.text("Finishing…"), false)
        }
    }

    /// A paused card promises Resume only while no linked attempt has taken
    /// it over. Once one has, a Resume here would run against files that
    /// attempt already published, so the headline points onward instead. It
    /// stays a non-problem headline, like the paused verdict itself.
    nonisolated static func pausedHeadline(continuedInLinkedAttempt: Bool) -> String {
        continuedInLinkedAttempt
            ? L10n.text("Paused · continued in a linked attempt")
            : L10n.text("Paused safely · Resume available")
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
        /// Every pair at this destination landed — verified, or under Fast
        /// transferred and still owed a read-back — but the transfer did not
        /// verify: its evidence or ASC MHL could not be written, the source
        /// changed or could not be re-scanned after the copy, another
        /// destination failed, or Cancel landed. Red, never green or yellow.
        case transferNotVerified
    }

    func destinationState(_ destination: URL) -> DestinationState {
        if let report {
            return Self.terminalDestinationState(of: report, at: destination)
        }
        switch progress.phase {
        case .enumerating, .preReadingSource: return .pending
        case .copying: return .copying
        default: return .verifying
        }
    }

    /// One destination's terminal tile state, from the report alone. Green
    /// needs all three: every pair here verified, the transfer's own verdict
    /// verified, and this destination among the places its evidence landed.
    /// Fast's yellow has the same shape: every pair here landed, a
    /// transferred-pending-verification verdict, and evidence here. The
    /// engine fails or cancels a run without touching any pair's outcome
    /// (evidence or MHL write failure, post-copy source re-scan veto, Cancel
    /// while finalizing, a failure at another destination), so outcomes alone
    /// never earn green or yellow.
    nonisolated static func terminalDestinationState(
        of report: TransferReport,
        at destination: URL
    ) -> DestinationState {
        if report.status == .paused { return .paused }
        let outcomes = report.items.map { $0.outcomes[destination] }
        // Landed: read back and matched, or (Fast) copied and still owed a
        // read-back. Anything else is this destination's own failure.
        let everyPairLanded = !outcomes.isEmpty && outcomes.allSatisfy {
            $0?.isVerified == true || $0?.isTransferredPendingVerification == true
        }
        guard everyPairLanded else { return .failed }
        let hasEvidence = report.manifestLocations.contains(destination)
        switch report.status {
        case .verified:
            let everyPairVerified = outcomes.allSatisfy { $0?.isVerified == true }
            return everyPairVerified && hasEvidence ? .verified : .transferNotVerified
        case .transferredPendingVerification:
            return hasEvidence ? .pendingVerification : .transferNotVerified
        case .failed, .cancelled, .paused:
            return .transferNotVerified
        }
    }

    /// The red `transferNotVerified` text says what did happen here: every
    /// copy was read back and matched, or (Fast) copies landed that nobody
    /// read back. Neither wording is the success one.
    nonisolated static func transferNotVerifiedText(of report: TransferReport, at destination: URL) -> String {
        let everyPairVerified = !report.items.isEmpty
            && report.items.allSatisfy { $0.outcomes[destination]?.isVerified == true }
        return everyPairVerified
            ? L10n.text("Copies verified · transfer not verified")
            : L10n.text("Transferred · transfer not verified")
    }

    func destinationFraction(_ destination: URL) -> Double {
        if let report {
            return Self.reportedFraction(of: report, at: destination)
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

    /// The terminal per-destination fraction. Both verified and
    /// transferred-pending-verification bytes have landed, so both count —
    /// the yellow state, not the number, says verification is still owed.
    /// A destination with any failure keeps its shape: verified bytes only.
    nonisolated static func reportedFraction(of report: TransferReport, at destination: URL) -> Double {
        let total = report.items.reduce(Int64(0)) { $0 + $1.item.size }
        guard total > 0 else { return 0 }
        let hasFailure = report.items.contains {
            if case .failed = $0.outcomes[destination] { return true } else { return false }
        }
        let landed = report.items.reduce(Int64(0)) { value, item in
            guard let outcome = item.outcomes[destination] else { return value }
            if outcome.isVerified { return value + item.item.size }
            if !hasFailure, outcome.isTransferredPendingVerification { return value + item.item.size }
            return value
        }
        return min(Double(landed) / Double(total), 1)
    }

    /// Windowed like the overall rate, with the same cumulative fallback.
    func destinationThroughput(_ destination: URL) -> Double {
        guard isRunning, let runStarted else { return 0 }
        let now = Date()
        if let windowed = ThroughputWindow.rate(
            samples: destinationThroughputSamples[destination] ?? [],
            now: now.timeIntervalSinceReferenceDate
        ) {
            return windowed
        }
        let elapsed = now.timeIntervalSince(runStarted)
        guard elapsed > 0.5 else { return 0 }
        return Double(destinationDoneBytes(destination)) / elapsed
    }

    func destinationETA(_ destination: URL) -> Double? {
        let rate = destinationThroughput(destination)
        guard rate > 0 else { return nil }
        let passes: Int64 = verificationProfile == .fast ? 1 : 2
        let total = planTotalBytes * passes
        return max(Double(total - destinationDoneBytes(destination)) / rate, 0)
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
        case .transferNotVerified:
            // Only a terminal report produces this state.
            return report.map { Self.transferNotVerifiedText(of: $0, at: destination) } ?? L10n.text("Incomplete")
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

    var canEjectSource: Bool {
        guard report?.status == .verified, let sourceVolume else { return false }
        return sourceVolume.isRemovable
            && RealFileSystem().canonicalURL(source).path == sourceVolume.mountPath
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

// MARK: - Sliding-window throughput

/// One progress observation: seconds since the reference date, and the bytes
/// finished at that moment.
struct ThroughputSample: Equatable, Sendable {
    let time: TimeInterval
    let bytes: Int64
}

/// Pure arithmetic for a rate over the most recent few seconds of samples,
/// so a display rate answers "how fast right now" rather than "how fast on
/// average since launch".
enum ThroughputWindow {
    /// How far back the rate looks.
    static let duration: TimeInterval = 5
    /// Hard cap on retained samples; progress is throttled well below this
    /// over a 5 s window, so the cap is only a guard.
    static let maxSamples = 128

    /// Bytes per second over the window ending at `now`, or `nil` when fewer
    /// than two samples span a positive interval — callers fall back to the
    /// cumulative rate then. The reference point is the newest sample at or
    /// before `now - window`, or the oldest sample when none is that old, so
    /// a young transfer still measures over everything it has.
    static func rate(
        samples: [ThroughputSample],
        now: TimeInterval,
        window: TimeInterval = duration
    ) -> Double? {
        guard samples.count >= 2, let latest = samples.last else { return nil }
        let cutoff = now - window
        let reference = samples.dropLast().last(where: { $0.time <= cutoff }) ?? samples[0]
        guard reference.time < latest.time else { return nil }
        let elapsed = max(now, latest.time) - reference.time
        let delta = latest.bytes - reference.bytes
        return max(Double(delta) / elapsed, 0)
    }

    /// Appends `sample` and prunes to what `rate` needs: everything inside
    /// the window plus the single newest sample older than it.
    static func appending(
        _ sample: ThroughputSample,
        to samples: [ThroughputSample],
        now: TimeInterval,
        window: TimeInterval = duration
    ) -> [ThroughputSample] {
        var kept = samples
        kept.append(sample)
        let cutoff = now - window
        if let referenceIndex = kept.lastIndex(where: { $0.time <= cutoff }), referenceIndex > 0 {
            kept.removeFirst(referenceIndex)
        }
        if kept.count > maxSamples {
            kept.removeFirst(kept.count - maxSamples)
        }
        return kept
    }
}
