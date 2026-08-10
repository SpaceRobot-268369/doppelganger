import Foundation

/// Serializes every event onto the engine's stream and throttles `.progress`
/// so consumers see at most ~1/interval snapshots, plus guaranteed emissions
/// on phase and item boundaries. Copy-pass and verify-pass tasks all report
/// through here, which keeps event ordering coherent.
actor ProgressHub {
    private let continuation: AsyncStream<TransferEvent>.Continuation
    private let interval: Duration
    private let clock = ContinuousClock()
    private var lastEmit: ContinuousClock.Instant?
    private var progress = TransferProgress(phase: .enumerating)

    init(continuation: AsyncStream<TransferEvent>.Continuation, interval: Duration) {
        self.continuation = continuation
        self.interval = interval
    }

    func phase(_ phase: TransferPhase) {
        progress.phase = phase
        progress.currentRelativePath = nil
        continuation.yield(.phaseChanged(phase))
        emit(force: true)
    }

    func plan(totalBytes: Int64, itemsTotal: Int) {
        progress.totalBytes = totalBytes
        progress.itemsTotal = itemsTotal
        continuation.yield(.planReady(itemCount: itemsTotal, totalBytes: totalBytes))
    }

    func beginItem(_ relativePath: String) {
        progress.currentRelativePath = relativePath
        emit(force: false)
    }

    func finishItem() {
        progress.itemsCopied += 1
        emit(force: true)
    }

    func addCopiedBytes(_ count: Int) {
        progress.copiedBytes += Int64(count)
        emit(force: false)
    }

    func addCopiedBytes(_ count: Int, at destination: URL) {
        progress.copiedBytesByDestination[destination, default: 0] += Int64(count)
        emit(force: false)
    }

    func addVerifiedBytes(_ count: Int, at destination: URL) {
        progress.verifiedBytesByDestination[destination, default: 0] += Int64(count)
        emit(force: false)
    }

    func outcome(_ relativePath: String, destination: URL, _ outcome: ItemDestinationOutcome) {
        continuation.yield(.itemOutcome(relativePath: relativePath, destination: destination, outcome: outcome))
    }

    func log(_ level: TransferLogEntry.Level, _ message: String) {
        continuation.yield(.log(TransferLogEntry(level: level, message: message)))
    }

    /// Terminal: emits the report and ends the stream. Every code path through
    /// the worker funnels here exactly once — interruption never produces
    /// silence.
    func finished(_ report: TransferReport) {
        continuation.yield(.finished(report))
        continuation.finish()
    }

    private func emit(force: Bool) {
        let now = clock.now
        if !force, let lastEmit, now - lastEmit < interval { return }
        lastEmit = now
        continuation.yield(.progress(progress))
    }
}
