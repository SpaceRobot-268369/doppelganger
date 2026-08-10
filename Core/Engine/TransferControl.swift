actor TransferControl {
    private var pauseRequested = false

    func reset() {
        pauseRequested = false
    }

    func requestPause() {
        pauseRequested = true
    }

    func shouldPause() -> Bool {
        pauseRequested
    }
}
