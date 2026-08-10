import Foundation

/// Deterministic JSON encoding for the manifest: identical input produces
/// byte-identical output, so manifests can be diffed and snapshot-tested.
public enum ManifestWriter {
    public static func jsonData(for manifest: TransferManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    public static func decode(_ data: Data) throws -> TransferManifest {
        try JSONDecoder().decode(TransferManifest.self, from: data)
    }

    /// File names generated for a transfer, shared by every location the
    /// records are written to (destinations and spool).
    public static func manifestFileName(shortID: String) -> String {
        "doppelganger-manifest-\(shortID).json"
    }

    public static func reportFileName(shortID: String) -> String {
        "doppelganger-report-\(shortID).md"
    }

    public static func logFileName(shortID: String) -> String {
        "doppelganger-transfer-\(shortID).log"
    }
}
