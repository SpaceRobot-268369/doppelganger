import Foundation
import Observation

/// Owns the single-transfer flow: setup → running → report. Consumes the
/// engine's event stream on the main actor and mirrors it into observable
/// state for the views.
@MainActor
@Observable
final class TransferViewModel {
    enum Stage {
        case setup
        case running
        case report(TransferReport)
    }

    // MARK: - Observable state

    private(set) var stage: Stage = .setup

    var source: URL? {
        didSet { persistSelections() }
    }
    var destinations: [URL] = [] {
        didSet { persistSelections() }
    }

    private(set) var progress = TransferProgress(phase: .enumerating)
    private(set) var planItemCount = 0
    private(set) var planTotalBytes: Int64 = 0
    private(set) var logEntries: [TransferLogEntry] = []
    /// Failures observed live during the run, newest last.
    private(set) var liveFailures: [(relativePath: String, destination: URL, reason: String)] = []
    private(set) var cancelRequested = false
    var showLog = false

    // MARK: - Dependencies

    private let engine: TransferEngine
    private let selectionStore: any SelectionStore
    private var logStore: TransferLogStore?
    private var consumeTask: Task<Void, Never>?
    private var runStarted: Date?
    private var runDestinationCount = 1
    private(set) var lastLogFileURL: URL?

    init(
        engine: TransferEngine? = nil,
        selectionStore: any SelectionStore = UserDefaultsSelectionStore()
    ) {
        self.engine = engine ?? TransferEngine(
            fileSystem: RealFileSystem(),
            sleepInhibitor: ProcessSleepInhibitor()
        )
        self.selectionStore = selectionStore
        let saved = selectionStore.load()
        source = saved.source
        destinations = saved.destinations
    }

    // MARK: - Setup validation

    var validationMessage: String? {
        guard let source else { return "Choose a source to offload." }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return "The source folder is not mounted."
        }
        guard !destinations.isEmpty else { return "Add at least one destination." }
        let sourcePath = source.standardizedFileURL.path
        var seen = Set<String>()
        for destination in destinations {
            let path = destination.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                return "Destination \(destination.lastPathComponent) is not mounted."
            }
            guard seen.insert(path).inserted else {
                return "The same destination is listed twice."
            }
            if path == sourcePath || path.hasPrefix(sourcePath + "/") {
                return "A destination is inside the source."
            }
            if sourcePath.hasPrefix(path + "/") {
                return "The source is inside a destination."
            }
        }
        return nil
    }

    var canStart: Bool { validationMessage == nil }

    func addDestination(_ url: URL) {
        destinations.append(url)
    }

    func removeDestination(at index: Int) {
        guard destinations.indices.contains(index) else { return }
        destinations.remove(at: index)
    }

    // MARK: - Transfer lifecycle

    func start() {
        guard let source, canStart, consumeTask == nil else { return }
        let request = TransferRequest(
            sourceRoot: source,
            destinationRoots: destinations,
            spoolDirectory: Self.spoolDirectory
        )
        let spoolTarget = Self.spoolDirectory.appendingPathComponent(request.shortID, isDirectory: true)
        let store = TransferLogStore(spoolTarget: spoolTarget, shortID: request.shortID)
        logStore = store
        lastLogFileURL = store.fileURL

        progress = TransferProgress(phase: .enumerating)
        planItemCount = 0
        planTotalBytes = 0
        logEntries = []
        liveFailures = []
        cancelRequested = false
        runStarted = Date()
        runDestinationCount = max(destinations.count, 1)
        stage = .running

        consumeTask = Task { [weak self, engine] in
            let stream = await engine.run(request)
            for await event in stream {
                self?.handle(event)
            }
            self?.consumeTask = nil
        }
    }

    func cancel() {
        cancelRequested = true
        Task { [engine] in
            await engine.cancel()
        }
    }

    func newTransfer() {
        stage = .setup
        showLog = false
    }

    // MARK: - Derived progress

    /// Copy + verify are one budget: total work is plan bytes × (1 copy pass
    /// + one verify pass per destination).
    var overallFraction: Double {
        let total = Double(planTotalBytes) * Double(1 + runDestinationCount)
        guard total > 0 else { return 0 }
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        return min(done / total, 1)
    }

    var throughputBytesPerSecond: Double {
        guard let runStarted else { return 0 }
        let elapsed = Date().timeIntervalSince(runStarted)
        guard elapsed > 0.5 else { return 0 }
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        return done / elapsed
    }

    var etaSeconds: Double? {
        let rate = throughputBytesPerSecond
        guard rate > 0 else { return nil }
        let total = Double(planTotalBytes) * Double(1 + runDestinationCount)
        let done = Double(progress.copiedBytes) +
            Double(progress.verifiedBytesByDestination.values.reduce(0, +))
        guard total > done else { return 0 }
        return (total - done) / rate
    }

    func verifyFraction(for destination: URL) -> Double {
        guard planTotalBytes > 0 else { return 0 }
        let verified = progress.verifiedBytesByDestination[destination] ?? 0
        return min(Double(verified) / Double(planTotalBytes), 1)
    }

    // MARK: - Event handling

    private func handle(_ event: TransferEvent) {
        switch event {
        case .phaseChanged(let phase):
            progress.phase = phase
        case .planReady(let itemCount, let totalBytes):
            planItemCount = itemCount
            planTotalBytes = totalBytes
        case .progress(let snapshot):
            progress = snapshot
        case .itemOutcome(let relativePath, let destination, let outcome):
            if case .failed(let reason) = outcome {
                liveFailures.append((relativePath, destination, reason.slug))
            }
        case .log(let entry):
            logEntries.append(entry)
            logStore?.append(entry)
        case .finished(let report):
            logStore?.close()
            logStore = nil
            stage = .report(report)
        }
    }

    // MARK: - Persistence

    private func persistSelections() {
        selectionStore.save(source: source, destinations: destinations)
    }

    static var spoolDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
            .appendingPathComponent("Transfers", isDirectory: true)
    }
}
