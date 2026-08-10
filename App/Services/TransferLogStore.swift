import Foundation
import os

/// Persists the live transfer log: every entry goes to a per-transfer `.log`
/// file in the spool directory and to OSLog for developer diagnostics.
final class TransferLogStore {
    private static let osLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger",
        category: "transfer"
    )

    let fileURL: URL
    private var handle: FileHandle?

    init(spoolTarget: URL, shortID: String) {
        fileURL = spoolTarget.appendingPathComponent(ManifestWriter.logFileName(shortID: shortID))
        do {
            try FileManager.default.createDirectory(at: spoolTarget, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
        } catch {
            handle = nil
            Self.osLog.error("Could not open transfer log at \(self.fileURL.path): \(String(describing: error))")
        }
    }

    func append(_ entry: TransferLogEntry) {
        switch entry.level {
        case .info: Self.osLog.info("\(entry.message)")
        case .warning: Self.osLog.warning("\(entry.message)")
        case .error: Self.osLog.error("\(entry.message)")
        }
        guard let handle else { return }
        try? handle.write(contentsOf: Data((entry.formattedLine + "\n").utf8))
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
