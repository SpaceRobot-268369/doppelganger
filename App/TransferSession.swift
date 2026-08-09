import Foundation
import Observation

/// One transfer, from launch to terminal report. Each session owns its own
/// engine instance, so several offloads can run side by side; the dashboard
/// lists sessions in creation order.
@MainActor
@Observable
final class TransferSession: Identifiable {
    let id: UUID
    let label: String
    let source: URL
    let destinationBases: [URL]
    let destinations: [URL]
    let algorithm: ChecksumAlgorithm
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
    private(set) var report: TransferReport?
    private(set) var lastLogFileURL: URL?
    private(set) var started = false
    private(set) var partialCleanupMessage: String?
    var showLog = false

    /// Fired once, on the main actor, when the terminal report arrives — the
    /// queue scheduler and notifier hang off this.
    var onFinished: (() -> Void)?

    private let engine: TransferEngine
    private var logStore: TransferLogStore?
    private var consumeTask: Task<Void, Never>?
    private var runStarted: Date?
    private let journalStore: TransferJournalStore
    private var journal: TransferJournal

    init(
        id: UUID = UUID(),
        label: String,
        source: URL,
        destinations: [TransferDestination],
        algorithm: ChecksumAlgorithm = .xxh64,
        allowSameVolume: Bool = false,
        createdAt: Date = Date(),
        recoveredIssue: String? = nil,
        engine: TransferEngine? = nil
    ) {
        self.id = id
        self.label = label
        self.source = source
        destinationBases = destinations.map(\.baseRoot)
        self.destinations = destinations.map(\.outputRoot)
        self.algorithm = algorithm
        self.allowSameVolume = allowSameVolume
        self.createdAt = createdAt
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
            label: label,
            source: source,
            destinationBases: destinations.map(\.baseRoot),
            destinations: destinations.map(\.outputRoot),
            algorithm: algorithm,
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
            label: journal.label,
            source: journal.source,
            destinations: zip(journal.destinationBases, journal.destinations).map {
                TransferDestination(baseRoot: $0.0, outputRoot: $0.1)
            },
            algorithm: journal.algorithm,
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
    var hasAttention: Bool {
        !liveFailures.isEmpty || (report.map { $0.status != .verified } ?? false)
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
            spoolDirectory: Self.spoolDirectory,
            allowSameVolume: allowSameVolume,
            requireNewOutputRoots: true
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
            return report.status == .verified ? 1 : lastKnownFraction
        }
        return lastKnownFraction
    }

    private var lastKnownFraction: Double {
        let total = Double(planTotalBytes) * Double(1 + max(destinations.count, 1))
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
        let total = Double(planTotalBytes) * Double(1 + max(destinations.count, 1))
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
        planTotalBytes * Int64(1 + max(destinations.count, 1))
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
        case verified
        case failed
    }

    func destinationState(_ destination: URL) -> DestinationState {
        if let report {
            let failures = report.items.filter {
                if case .failed = $0.outcomes[destination] { return true } else { return false }
            }.count
            let verified = report.items.filter { $0.outcomes[destination]?.isVerified == true }.count
            if failures > 0 { return .failed }
            return verified == report.items.count && !report.items.isEmpty ? .verified : .failed
        }
        switch progress.phase {
        case .enumerating: return .pending
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
            return min(Double(progress.copiedBytes) / Double(planTotalBytes), 1)
        default:
            return verifyFraction(for: destination)
        }
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
        let errorText = "\(errors) error\(errors == 1 ? "" : "s")"
        switch destinationState(destination) {
        case .pending: return "Waiting"
        case .copying: return "Copying · \(errorText)"
        case .verifying: return "Verifying · \(errorText)"
        case .verified: return "Verified · \(errorText)"
        case .failed: return errors > 0 ? "Failed · \(errorText)" : "Incomplete"
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
        return report.destinations
            .map { $0.appendingPathComponent(MHLWriter.fileName(shortID: report.shortID)) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
            ? "Removed \(removed) temporary file\(removed == 1 ? "" : "s")."
            : "Removed \(removed) temporary files; \(failures) could not be removed."
    }

    static var spoolDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
    }
}
