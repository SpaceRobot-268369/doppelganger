import Foundation

enum SourcePlanFingerprint {
    /// Stable source-plan identity: normalized relative paths, sizes, and
    /// source timestamps. It narrows prior evidence candidates but is never a
    /// substitute for a content digest.
    static func make(_ items: [SourceItem]) -> String {
        let hasher = XXH3Streaming()
        for item in items.sorted(by: { $0.relativePath < $1.relativePath }) {
            // Millisecond normalization survives ordinary filesystem timestamp
            // round-trips while still detecting meaningful source-plan edits.
            let timestamp = item.modificationTime.map {
                String(Int64(($0 * 1_000).rounded()))
            } ?? "-"
            let line = "\(item.relativePath)\0\(item.size)\0\(timestamp)\n"
            Data(line.utf8).withUnsafeBytes { hasher.update($0) }
        }
        return hasher.hexDigest()
    }
}
