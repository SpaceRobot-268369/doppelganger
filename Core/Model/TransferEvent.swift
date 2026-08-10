import Foundation

/// The engine's event stream. Consumers may drop `.progress` and `.log`
/// events; `.finished` always arrives exactly once, on every terminal path —
/// interruption never produces silence.
public enum TransferEvent: Sendable {
    case phaseChanged(TransferPhase)
    case planReady(itemCount: Int, totalBytes: Int64)
    case progress(TransferProgress)
    case itemOutcome(relativePath: String, destination: URL, outcome: ItemDestinationOutcome)
    case log(TransferLogEntry)
    case finished(TransferReport)
}
