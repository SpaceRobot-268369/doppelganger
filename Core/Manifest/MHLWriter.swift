import Foundation

/// Media Hash List (MHL) v1.1 output — the interchange format facilities and
/// other offload tools verify against.
///
/// One MHL is written per destination only after the complete transfer is
/// verified. A failed or cancelled run never emits a partial MHL that could be
/// mistaken for proof that the whole card completed; its detail lives in the
/// JSON manifest and Markdown report.
public enum MHLWriter {
    public static func fileName(shortID: String) -> String {
        "doppelganger-\(shortID).mhl"
    }

    /// The MHL XML for one destination, or `nil` if nothing verified there.
    /// Deterministic: identical report input produces byte-identical output.
    public static func xml(for report: TransferReport, destination: URL) -> String? {
        // A partial MHL beside a failed transfer can be mistaken for evidence
        // that the whole card is complete. Failed/cancelled detail remains in
        // the JSON manifest and report; retry produces a fresh complete MHL.
        guard report.status == .verified else { return nil }
        let verified = report.items.filter { $0.outcomes[destination]?.isVerified == true }
        guard !verified.isEmpty else { return nil }

        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let digestTag: String = switch report.algorithm {
        case .xxh64: "xxhash64be"
        case .md5: "md5"
        }

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<hashlist version="1.1">"#)
        lines.append("  <creatorinfo>")
        lines.append("    <name>doppelganger</name>")
        lines.append("    <tool>doppelganger</tool>")
        lines.append("    <startdate>\(report.startedAt.formatted(iso))</startdate>")
        lines.append("    <finishdate>\(report.finishedAt.formatted(iso))</finishdate>")
        lines.append("  </creatorinfo>")
        for item in verified {
            // Digest is always present on a verified item; skip defensively if
            // a malformed report says otherwise rather than emit a lying entry.
            guard let digest = item.sourceDigest else { continue }
            lines.append("  <hash>")
            lines.append("    <file>\(escape(item.item.relativePath))</file>")
            lines.append("    <size>\(item.item.size)</size>")
            lines.append("    <\(digestTag)>\(digest)</\(digestTag)>")
            lines.append("    <hashdate>\(report.finishedAt.formatted(iso))</hashdate>")
            lines.append("  </hash>")
        }
        lines.append("</hashlist>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
