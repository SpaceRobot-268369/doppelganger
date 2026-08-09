/// Keeps the machine awake while a transfer runs. Platform backs this with
/// `ProcessInfo` activity assertions; tests inject a no-op.
public protocol SleepInhibiting: Sendable {
    func beginInhibition(reason: String) -> any SleepInhibitionToken
}

public protocol SleepInhibitionToken: Sendable {
    func release()
}

/// Test double and safe default.
public struct NoopSleepInhibitor: SleepInhibiting {
    public init() {}
    public func beginInhibition(reason: String) -> any SleepInhibitionToken { Token() }
    private struct Token: SleepInhibitionToken {
        func release() {}
    }
}
