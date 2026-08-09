import Foundation

/// One line of the transfer log: shown live in the UI and appended to the
/// per-transfer `.log` file.
public struct TransferLogEntry: Sendable, Hashable, Identifiable {
    public enum Level: String, Sendable, Hashable {
        case info
        case warning
        case error
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    /// Stable single-line rendering for the persisted log file.
    public var formattedLine: String {
        let time = timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "[\(time)] [\(level.rawValue)] \(message)"
    }
}
