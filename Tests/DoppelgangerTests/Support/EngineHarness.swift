import Foundation
import Testing
@testable import Doppelganger

/// Runs one transfer against a fixture and collects everything the engine
/// emitted, for assertion.
enum EngineHarness {
    struct Run {
        let report: TransferReport
        let events: [TransferEvent]

        var phases: [TransferPhase] {
            events.compactMap { if case .phaseChanged(let phase) = $0 { phase } else { nil } }
        }

        var logMessages: [String] {
            events.compactMap { if case .log(let entry) = $0 { entry.message } else { nil } }
        }
    }

    static func run(
        fileSystem: any FileSystemAccess,
        source: URL,
        destinations: [URL],
        spool: URL,
        chunkSize: Int = 64 * 1024,
        cancelWhen: (@Sendable (TransferEvent) -> Bool)? = nil
    ) async throws -> Run {
        let engine = TransferEngine(
            fileSystem: fileSystem,
            configuration: TransferConfiguration(chunkSize: chunkSize, progressInterval: .milliseconds(1))
        )
        let request = TransferRequest(sourceRoot: source, destinationRoots: destinations, spoolDirectory: spool)
        var events: [TransferEvent] = []
        var report: TransferReport?
        var cancelSent = false
        for await event in await engine.run(request) {
            events.append(event)
            if !cancelSent, let cancelWhen, cancelWhen(event) {
                cancelSent = true
                await engine.cancel()
            }
            if case .finished(let finished) = event { report = finished }
        }
        return Run(report: try #require(report, "stream must end with .finished"), events: events)
    }

    /// The standard three-file card used by most engine tests. Sizes chosen so
    /// the default 64 KiB test chunk size exercises multi-chunk files.
    static let standardFiles: [FixtureBuilder.FileSpec] = [
        .init("DCIM/100MEDIA/a.bin", size: 200_000, seed: 1),
        .init("DCIM/100MEDIA/b.bin", size: 150_000, seed: 2),
        .init("MISC/c.txt", size: 1_000, seed: 3),
    ]

    static func decodeManifest(at root: URL, shortID: String) throws -> TransferManifest {
        let url = root.appendingPathComponent(ManifestWriter.manifestFileName(shortID: shortID))
        return try ManifestWriter.decode(Data(contentsOf: url))
    }
}

extension TransferReport {
    func outcome(_ relativePath: String, at destination: URL) -> ItemDestinationOutcome? {
        items.first { $0.item.relativePath == relativePath }?.outcomes[destination]
    }

    var spoolLocation: URL? {
        manifestLocations.first { $0.lastPathComponent == shortID }
    }
}
