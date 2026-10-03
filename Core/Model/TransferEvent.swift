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
    /// An ASC MHL generation was appended at `destination` and the chain
    /// index updated. Emitted only after every destination's append
    /// succeeded, before `.finished`, so a durable journal can roll the
    /// generation back if the process dies before the terminal record lands.
    /// `archiveURL` is the pre-append chain copy, `nil` when this was the
    /// first generation in the directory.
    case mhlGenerationWritten(destination: URL, generationURL: URL, chainURL: URL, archiveURL: URL?)
    case finished(TransferReport)
}
