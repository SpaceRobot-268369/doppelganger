import Foundation

/// Keeps the machine from idle-sleeping while a transfer runs, via
/// `ProcessInfo` activity assertions (visible in `pmset -g assertions`).
public struct ProcessSleepInhibitor: SleepInhibiting {
    public init() {}

    public func beginInhibition(reason: String) -> any SleepInhibitionToken {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
        return Token(activity: activity)
    }

    private final class Token: SleepInhibitionToken, @unchecked Sendable {
        private let activity: NSObjectProtocol
        private let lock = NSLock()
        private var released = false

        init(activity: NSObjectProtocol) {
            self.activity = activity
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            ProcessInfo.processInfo.endActivity(activity)
        }
    }
}
