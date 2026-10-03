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

    /// One `<hash>` record: a pair this attempt verified, or (repair) one its
    /// failed parent verified at the same destination.
    struct HashRecord: Sendable {
        let relativePath: String
        let size: Int64
        let modifiedAt: String?
        let digest: String
        let hashDate: String
    }

    /// What the destination folder contributes to a generation, gathered by
    /// `MHLHistoryStore` before anything is written.
    struct FolderContext: Sendable {
        /// File records of every earlier generation in this folder's chain.
        var history: [MHLDocument.Entry] = []
        /// Pairs a failed parent attempt verified here (repair only). Each is
        /// listed only as a path's first original.
        var carried: [HashRecord] = []
        /// Regular files now under the destination root. `nil` when the folder
        /// could not be listed, which suppresses every directory hash.
        var folderMedia: Set<String>?
    }

    /// Written to every generation's `<ignore>`: doppelganger's own evidence,
    /// the retry quarantine tree, and the operating-system metadata
    /// `FileSystemAccess.enumerate` never reports, so another tool hashes
    /// exactly the files a generation can describe.
    static let ignorePatterns = [
        ".DS_Store", "ascmhl", "ascmhl/", "doppelganger-*",
        ".doppelganger-failed", ".doppelganger-failed/", ".doppelganger-partial-*",
        "._*", ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems",
    ]

    /// `ignorePatterns` as a path test. No pattern holds an inner "/", so each
    /// matches a file or directory name at any depth; a trailing "*" is a prefix.
    static func isIgnored(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").contains { name in
            ignorePatterns.contains { pattern in
                let pattern = pattern.hasSuffix("/") ? pattern.dropLast() : Substring(pattern)
                return pattern.hasSuffix("*") ? name.hasPrefix(pattern.dropLast()) : name == pattern
            }
        }
    }

    /// Whether `digest` is `algorithm`'s canonical form: lowercase hex of the
    /// algorithm's width, the only form its hashers produce.
    static func isWellFormedDigest(_ digest: String, algorithm: ChecksumAlgorithm) -> Bool {
        let width = switch algorithm {
        case .xxh3, .xxh64: 16
        case .md5: 32
        }
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        let letters = UInt8(ascii: "a")...UInt8(ascii: "f")
        return digest.utf8.count == width
            && digest.utf8.allSatisfy { digits.contains($0) || letters.contains($0) }
    }

    /// Throws `MHLHistoryError.conflictingHistory` when the folder's history
    /// already holds a hash this generation would contradict, and
    /// `MHLHistoryError.malformedDigest` when a hash it would record is not a
    /// well-formed digest in the report's format.
    static func generation(
        for report: TransferReport,
        destination: URL,
        sequence: Int,
        context: FolderContext,
        hostName: String = ProcessInfo.processInfo.hostName,
        mediaVolumeIdentifier: String? = nil
    ) throws -> Generation? {
        guard report.status == .verified else { return nil }
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let hashDate = report.finishedAt.formatted(iso)
        let verified = report.items.compactMap { item -> HashRecord? in
            guard item.outcomes[destination]?.isVerified == true, let digest = item.sourceDigest else { return nil }
            return HashRecord(
                relativePath: item.item.relativePath,
                size: item.item.size,
                modifiedAt: item.item.modificationTime.map { Date(timeIntervalSince1970: $0).formatted(iso) },
                digest: digest.lowercased(),
                hashDate: hashDate
            )
        }
        guard !verified.isEmpty else { return nil }
        // A carried hash, or one a resume restored, was read back from a
        // manifest on disk rather than computed by this attempt. One that is
        // not a digest in this format would make the generation malformed or
        // schema-invalid, and every later append to the folder's history would
        // then fail, so it refuses the generation instead.
        if let malformed = (verified + context.carried).first(where: {
            !isWellFormedDigest($0.digest, algorithm: report.algorithm)
        }) {
            throw MHLHistoryError.malformedDigest(path: malformed.relativePath)
        }
        let verifiedPaths = Set(verified.map(\.relativePath))
        let baseline = HistoryBaseline(context.history, algorithm: report.algorithm)
        // This attempt never re-read a carried copy, so a carried hash may only
        // supply a path's first original. Where the history already holds one,
        // the path is left to it rather than recorded as "verified" again.
        let carried = try context.carried.filter {
            try !verifiedPaths.contains($0.relativePath)
                && baseline.action(for: $0.relativePath, digest: $0.digest) == "original"
        }
        let records = (verified + carried).sorted { $0.relativePath < $1.relativePath }
        let actions = try records.map { try baseline.action(for: $0.relativePath, digest: $0.digest) }

        // A directory hash claims to describe everything beneath it, so one is
        // written only where this generation lists exactly the files on disk.
        let calculated = DirectoryHashes.calculate(
            items: records.map {
                ItemResult(
                    item: SourceItem(relativePath: $0.relativePath, size: $0.size),
                    sourceDigest: $0.digest,
                    outcomes: [:]
                )
            },
            algorithm: report.algorithm
        )
        let directories: [DirectoryHashes.Record] = context.folderMedia.map { folderMedia in
            let undescribed = undescribedDirectories(
                listed: Set(records.map(\.relativePath)),
                folderMedia: folderMedia
            )
            return calculated.filter { !undescribed.contains($0.path) }
        } ?? []

        let stamp = report.finishedAt.formatted(.iso8601)
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ":", with: "")
        let rootName = safeComponent(destination.lastPathComponent)
        let fileName = String(format: "%04d_%@_%@.mhl", sequence, rootName, stamp)
        let xml = xmlV2(
            report: report,
            hashes: Array(zip(records, actions)),
            directories: directories,
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

    /// Convenience used by previews/tests: the first generation of a folder
    /// holding exactly the verified files. Production writes a numbered
    /// generation plus `ascmhl_chain.xml` through `MHLHistoryStore`.
    public static func xml(for report: TransferReport, destination: URL) -> String? {
        let listed = report.items
            .filter { $0.outcomes[destination]?.isVerified == true && $0.sourceDigest != nil }
            .map(\.item.relativePath)
        let first = try? generation(
            for: report,
            destination: destination,
            sequence: 1,
            context: FolderContext(folderMedia: Set(listed))
        )
        return first.map { String(decoding: $0.data, as: UTF8.self) }
    }

    /// Directories (and ".") that a hash over `listed` would misdescribe: each
    /// one holding, at any depth, a file on disk the generation does not list,
    /// or a listed file that is not on disk or that other tools are told to ignore.
    static func undescribedDirectories(listed: Set<String>, folderMedia: Set<String>) -> Set<String> {
        let onDisk = folderMedia.filter { !isIgnored($0) }
        var undescribed: Set<String> = []
        for path in listed.symmetricDifference(onDisk) {
            var directory = DirectoryHashes.parentPath(path)
            while undescribed.insert(directory).inserted, directory != "." {
                directory = DirectoryHashes.parentPath(directory)
            }
        }
        return undescribed
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
        hashes: [(HashRecord, String)],
        directories: [DirectoryHashes.Record],
        hostName: String,
        mediaVolumeIdentifier: String?
    ) -> String {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let date = report.finishedAt.formatted(iso)
        let tag = digestTag(report.algorithm)
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
        for pattern in ignorePatterns {
            lines.append("      <pattern>\(escape(pattern))</pattern>")
        }
        lines.append("    </ignore>")
        lines.append("  </processinfo>")
        lines.append("  <hashes>")
        for (record, action) in hashes {
            let modified = record.modifiedAt.map { " lastmodificationdate=\"\(escape($0))\"" } ?? ""
            lines.append("    <hash>")
            lines.append("      <path size=\"\(record.size)\"\(modified)>\(escape(record.relativePath))</path>")
            lines.append("      <\(tag) action=\"\(action)\" hashdate=\"\(escape(record.hashDate))\">\(escape(record.digest))</\(tag)>")
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

/// ascmhl's action rule for a file hash: "original" until an earlier
/// generation holds an original for the path (in any format), then "verified"
/// when the earlier hashes in this format match. doppelganger appends only
/// verified transfers, so a mismatch, or an original it cannot compare in this
/// format, refuses the generation instead of recording "failed" or "new".
/// A record marked "failed", or with an action ASC MHL does not define, holds
/// a hash of bytes nothing vouches for and is no baseline.
private struct HistoryBaseline {
    private var withOriginal: Set<String> = []
    private var digests: [String: Set<String>] = [:]

    init(_ history: [MHLDocument.Entry], algorithm: ChecksumAlgorithm) {
        for entry in history where !entry.recordsUntrustedHash {
            if entry.recordsOriginalHash { withOriginal.insert(entry.relativePath) }
            if let digest = entry.digests[algorithm] {
                digests[entry.relativePath, default: []].insert(digest.lowercased())
            }
        }
    }

    func action(for path: String, digest: String) throws -> String {
        let prior = digests[path] ?? []
        guard prior.allSatisfy({ $0 == digest.lowercased() }) else {
            throw MHLHistoryError.conflictingHistory(path: path)
        }
        // Histories from older builds hold only "verified"; their next
        // generation supplies the original ascmhl looks for.
        guard withOriginal.contains(path) else { return "original" }
        guard !prior.isEmpty else { throw MHLHistoryError.conflictingHistory(path: path) }
        return "verified"
    }
}

private extension MHLDocument.Entry {
    var recordsOriginalHash: Bool { hashActions.contains("original") }
    /// An unannotated record (older writers) is trusted.
    var recordsUntrustedHash: Bool { untrustedHashAction != nil }
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

    static func parentPath(_ path: String) -> String {
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
