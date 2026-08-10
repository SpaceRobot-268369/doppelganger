import Foundation

/// Native ASC MHL v2 generation and chain writer. Media hashes come from the
/// independently verified transfer; directory hashes follow ASC MHL's
/// content/structure aggregation rules, and chain references use C4.
public enum MHLWriter {
    public struct Generation: Sendable, Equatable {
        public let sequence: Int
        public let fileName: String
        public let data: Data
        public let referenceC4: String
    }

    public struct ChainEntry: Sendable, Equatable {
        public let sequence: Int
        public let path: String
        public let c4: String

        public init(sequence: Int, path: String, c4: String) {
            self.sequence = sequence
            self.path = path
            self.c4 = c4
        }
    }

    /// Kept for locating evidence produced by older builds.
    public static func fileName(shortID: String) -> String {
        "doppelganger-\(shortID).mhl"
    }

    public static let directoryName = "ascmhl"
    public static let chainFileName = "ascmhl_chain.xml"

    public static func generation(
        for report: TransferReport,
        destination: URL,
        sequence: Int,
        hostName: String = ProcessInfo.processInfo.hostName,
        mediaVolumeIdentifier: String? = nil
    ) -> Generation? {
        guard report.status == .verified else { return nil }
        let verified = report.items
            .filter { $0.outcomes[destination]?.isVerified == true && $0.sourceDigest != nil }
            .sorted { $0.item.relativePath < $1.item.relativePath }
        guard !verified.isEmpty else { return nil }

        let stamp = report.finishedAt.formatted(.iso8601)
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ":", with: "")
        let rootName = safeComponent(destination.lastPathComponent)
        let fileName = String(format: "%04d_%@_%@.mhl", sequence, rootName, stamp)
        let xml = xmlV2(
            report: report,
            verified: verified,
            hostName: hostName,
            mediaVolumeIdentifier: mediaVolumeIdentifier
        )
        let data = Data(xml.utf8)
        return Generation(
            sequence: sequence,
            fileName: fileName,
            data: data,
            referenceC4: C4Checksum.digest(data)
        )
    }

    /// Convenience used by previews/tests; production writes a numbered
    /// generation plus `ascmhl_chain.xml` through `generation` and `chainXML`.
    public static func xml(for report: TransferReport, destination: URL) -> String? {
        generation(for: report, destination: destination, sequence: 1).map {
            String(decoding: $0.data, as: UTF8.self)
        }
    }

    public static func chainXML(entries: [ChainEntry]) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">"#,
        ]
        for entry in entries.sorted(by: { $0.sequence < $1.sequence }) {
            lines.append("  <hashlist sequencenr=\"\(entry.sequence)\">")
            lines.append("    <path>\(escape(entry.path))</path>")
            lines.append("    <c4>\(entry.c4)</c4>")
            lines.append("  </hashlist>")
        }
        lines.append("</ascmhldirectory>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func xmlV2(
        report: TransferReport,
        verified: [ItemResult],
        hostName: String,
        mediaVolumeIdentifier: String?
    ) -> String {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let date = report.finishedAt.formatted(iso)
        let tag = digestTag(report.algorithm)
        let directories = DirectoryHashes.calculate(items: verified, algorithm: report.algorithm)
        let root = directories.first { $0.path == "." }

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">"#)
        lines.append("  <creatorinfo>")
        lines.append("    <creationdate>\(date)</creationdate>")
        lines.append("    <hostname>\(escape(hostName))</hostname>")
        lines.append("    <tool version=\"1.0\">doppelganger</tool>")
        if let operatorSnapshot = report.operatorSnapshot {
            lines.append("    <author role=\"operator\">\(escape(operatorSnapshot.displayName))</author>")
        }
        lines.append("  </creatorinfo>")
        lines.append("  <processinfo>")
        lines.append("    <process>transfer</process>")
        if let root {
            lines.append("    <roothash>")
            lines.append("      <content><\(tag) hashdate=\"\(date)\">\(root.content)</\(tag)></content>")
            lines.append("      <structure><\(tag) hashdate=\"\(date)\">\(root.structure)</\(tag)></structure>")
            lines.append("    </roothash>")
        }
        lines.append("    <ignore>")
        lines.append("      <pattern>.DS_Store</pattern>")
        lines.append("      <pattern>ascmhl</pattern>")
        lines.append("      <pattern>ascmhl/</pattern>")
        lines.append("      <pattern>doppelganger-*</pattern>")
        lines.append("    </ignore>")
        lines.append("  </processinfo>")
        lines.append("  <hashes>")
        for item in verified {
            let modified = item.item.modificationTime.map {
                " lastmodificationdate=\"\(Date(timeIntervalSince1970: $0).formatted(iso))\""
            } ?? ""
            lines.append("    <hash>")
            lines.append("      <path size=\"\(item.item.size)\"\(modified)>\(escape(item.item.relativePath))</path>")
            lines.append("      <\(tag) action=\"verified\" hashdate=\"\(date)\">\(item.sourceDigest ?? "")</\(tag)>")
            lines.append("    </hash>")
        }
        for directory in directories.filter({ $0.path != "." }).sorted(by: { $0.path < $1.path }) {
            lines.append("    <directoryhash>")
            lines.append("      <path>\(escape(directory.path))</path>")
            lines.append("      <content><\(tag) hashdate=\"\(date)\">\(directory.content)</\(tag)></content>")
            lines.append("      <structure><\(tag) hashdate=\"\(date)\">\(directory.structure)</\(tag)></structure>")
            lines.append("    </directoryhash>")
        }
        lines.append("  </hashes>")
        if report.sourceFingerprint != nil || mediaVolumeIdentifier != nil {
            let fingerprint = report.sourceFingerprint.map { " sourceplanfingerprint=\"\(escape($0))\"" } ?? ""
            let volume = mediaVolumeIdentifier.map { " volumeidentifier=\"\(escape($0))\"" } ?? ""
            lines.append("  <metadata>")
            lines.append("    <doppelganger taskid=\"\(report.taskID.uuidString.lowercased())\" attemptid=\"\(report.id.uuidString.lowercased())\"\(fingerprint)\(volume) />")
            lines.append("  </metadata>")
        }
        lines.append("</hashlist>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func digestTag(_ algorithm: ChecksumAlgorithm) -> String {
        switch algorithm {
        case .xxh3: "xxh3"
        case .xxh64: "xxh64"
        case .md5: "md5"
        }
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        let mapped = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return String((mapped.isEmpty ? "media" : mapped).prefix(48))
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

enum DirectoryHashes {
    struct Record {
        let path: String
        let content: String
        let structure: String
    }

    static func calculate(items: [ItemResult], algorithm: ChecksumAlgorithm) -> [Record] {
        let files = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.sourceDigest.map { (item.item.relativePath, $0) }
        })
        var directories: Set<String> = ["."]
        for path in files.keys {
            var parent = parentPath(path)
            while parent != "." {
                directories.insert(parent)
                parent = parentPath(parent)
            }
        }
        var records: [String: Record] = [:]
        for directory in directories.sorted(by: { depth($0) > depth($1) }) {
            let directFiles = files.filter { parentPath($0.key) == directory }
            let directDirectories = records.values.filter { parentPath($0.path) == directory }
            let contentHashes = directFiles.map(\.value) + directDirectories.map(\.content)
            let structureHashes = directFiles.map { path, digest in
                hash(Data(baseName(path).utf8) + rawDigest(digest), algorithm: algorithm)
            } + directDirectories.map { child in
                hash(Data(baseName(child.path).utf8) + rawDigest(child.structure), algorithm: algorithm)
            }
            records[directory] = Record(
                path: directory,
                content: aggregate(contentHashes, algorithm: algorithm),
                structure: aggregate(structureHashes, algorithm: algorithm)
            )
        }
        return records.values.sorted { $0.path < $1.path }
    }

    private static func aggregate(_ digests: [String], algorithm: ChecksumAlgorithm) -> String {
        var hasher = algorithm.makeHasher()
        for digest in digests.sorted() {
            let bytes = rawDigest(digest)
            bytes.withUnsafeBytes { hasher.update($0) }
        }
        return hasher.hexDigest()
    }

    private static func hash(_ data: Data, algorithm: ChecksumAlgorithm) -> String {
        var hasher = algorithm.makeHasher()
        data.withUnsafeBytes { hasher.update($0) }
        return hasher.hexDigest()
    }

    private static func rawDigest(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        return Data(bytes)
    }

    private static func parentPath(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    private static func baseName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func depth(_ path: String) -> Int {
        path == "." ? 0 : path.split(separator: "/").count
    }
}
