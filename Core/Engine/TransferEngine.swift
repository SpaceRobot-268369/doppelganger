import Foundation

/// The offload engine. One task per engine instance: `run` starts the
/// pipeline on a detached task and returns its event stream; `cancel` requests
/// a defined interruption — the manifest is still written and the stream still
/// ends with `.finished`.
public actor TransferEngine {
    private let fileSystem: any FileSystemAccess
    private let sleepInhibitor: any SleepInhibiting
    private let configuration: TransferConfiguration
    private let control = TransferControl()
    private var runTask: Task<Void, Never>?

    public init(
        fileSystem: any FileSystemAccess,
        sleepInhibitor: any SleepInhibiting = NoopSleepInhibitor(),
        configuration: TransferConfiguration = TransferConfiguration()
    ) {
        self.fileSystem = fileSystem
        self.sleepInhibitor = sleepInhibitor
        self.configuration = configuration
    }

    public func run(_ request: TransferRequest) -> AsyncStream<TransferEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TransferEvent.self, bufferingPolicy: .unbounded)

        guard runTask == nil else {
            continuation.yield(.log(TransferLogEntry(
                level: .error, message: "A transfer is already running; ignoring request")))
            continuation.finish()
            return stream
        }

        let fileSystem = fileSystem
        let configuration = configuration
        let sleepInhibitor = sleepInhibitor
        let control = control

        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            await control.reset()
            let sleepToken = sleepInhibitor.beginInhibition(reason: "Doppelganger transfer \(request.shortID)")
            defer { sleepToken.release() }

            let hub = ProgressHub(continuation: continuation, interval: configuration.progressInterval)
            var worker = TransferWorker(
                request: request,
                configuration: configuration,
                fileSystem: fileSystem,
                hub: hub,
                control: control
            )
            await worker.run()
            await self?.clearRunTask()
        }
        return stream
    }

    public func cancel() {
        runTask?.cancel()
    }

    /// Requests a stop after the current complete source file reaches a safe
    /// boundary. It does not cancel or truncate the file in flight.
    public func pause() async {
        await control.requestPause()
    }

    public var isRunning: Bool { runTask != nil }

    private func clearRunTask() {
        runTask = nil
    }
}
