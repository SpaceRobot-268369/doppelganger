import Foundation

public struct MHLDocument: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let relativePath: String
        public let size: Int64
        public let digests: [ChecksumAlgorithm: String]
        public let hashDate: String?
        public let modifiedAt: String?
        public let action: String?

        public init(
            relativePath: String,
            size: Int64,
            digests: [ChecksumAlgorithm: String],
            hashDate: String? = nil,
            modifiedAt: String? = nil,
            action: String? = nil
        ) {
            self.relativePath = relativePath
            self.size = size
            self.digests = digests
            self.hashDate = hashDate
            self.modifiedAt = modifiedAt
            self.action = action
        }
    }

    public struct DirectoryEntry: Sendable, Hashable {
        public let relativePath: String
        public let contentDigests: [ChecksumAlgorithm: String]
        public let structureDigests: [ChecksumAlgorithm: String]
    }

    public let version: String?
    public let entries: [Entry]
    public let directories: [DirectoryEntry]
    public let rootContentDigests: [ChecksumAlgorithm: String]
    public let rootStructureDigests: [ChecksumAlgorithm: String]
    public let creationDate: String?
    public let sourcePlanFingerprint: String?
    public let mediaVolumeIdentifier: String?
}

public struct MHLChainDocument: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let sequence: Int
        public let path: String
        public let c4: String
    }

    public let entries: [Entry]
}

public enum MHLReader {
    public static func read(_ data: Data) throws -> MHLDocument {
        let delegate = ManifestParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? MHLReadError.invalidDocument
        }
        guard !delegate.entries.isEmpty else { throw MHLReadError.noHashes }
        return MHLDocument(
            version: delegate.version,
            entries: delegate.entries,
            directories: delegate.directories,
            rootContentDigests: delegate.rootContentDigests,
            rootStructureDigests: delegate.rootStructureDigests,
            creationDate: delegate.creationDate,
            sourcePlanFingerprint: delegate.sourcePlanFingerprint,
            mediaVolumeIdentifier: delegate.mediaVolumeIdentifier
        )
    }

    public static func readChain(_ data: Data) throws -> MHLChainDocument {
        let delegate = ChainParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.entries.isEmpty else {
            throw parser.parserError ?? MHLReadError.invalidChain
        }
        let sorted = delegate.entries.sorted { $0.sequence < $1.sequence }
        guard Set(sorted.map(\.sequence)).count == sorted.count,
              sorted.enumerated().allSatisfy({ $0.offset + 1 == $0.element.sequence })
        else { throw MHLReadError.invalidChain }
        return MHLChainDocument(entries: sorted)
    }

    public static func validateChain(
        at directory: URL,
        fileSystem: any FileSystemAccess = RealFileSystem()
    ) throws -> MHLChainDocument {
        let chainURL = directory.appendingPathComponent(MHLWriter.chainFileName)
        let chain = try readChain(readAll(chainURL, fileSystem: fileSystem))
        for entry in chain.entries {
            let manifestURL = directory.appendingPathComponent(entry.path)
            let data = try readAll(manifestURL, fileSystem: fileSystem)
            guard C4Checksum.digest(data) == entry.c4 else {
                throw MHLReadError.chainDigestMismatch(path: entry.path)
            }
            _ = try read(data)
        }
        return chain
    }

    static func readAll(_ url: URL, fileSystem: any FileSystemAccess) throws -> Data {
        let stream = try fileSystem.openForReading(url, uncached: true)
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = try stream.read(into: &buffer)
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private final class ManifestParserDelegate: NSObject, XMLParserDelegate {
        var version: String?
        var entries: [MHLDocument.Entry] = []
        var directories: [MHLDocument.DirectoryEntry] = []
        var rootContentDigests: [ChecksumAlgorithm: String] = [:]
        var rootStructureDigests: [ChecksumAlgorithm: String] = [:]
        var creationDate: String?
        var sourcePlanFingerprint: String?
        var mediaVolumeIdentifier: String?

        private enum RecordKind { case none, file, directory, root }
        private enum DigestContainer { case none, content, structure }
        private var recordKind: RecordKind = .none
        private var digestContainer: DigestContainer = .none
        private var text = ""
        private var path: String?
        private var size: Int64?
        private var digests: [ChecksumAlgorithm: String] = [:]
        private var contentDigests: [ChecksumAlgorithm: String] = [:]
        private var structureDigests: [ChecksumAlgorithm: String] = [:]
        private var hashDate: String?
        private var modifiedAt: String?
        private var action: String?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String] = [:]
        ) {
            let element = elementName.lowercased()
            text = ""
            switch element {
            case "hashlist": version = attributes["version"]
            case "hash":
                recordKind = .file
                path = nil
                size = nil
                digests = [:]
                hashDate = nil
                modifiedAt = nil
                action = nil
            case "directoryhash":
                recordKind = .directory
                path = nil
                contentDigests = [:]
                structureDigests = [:]
            case "roothash":
                recordKind = .root
                contentDigests = [:]
                structureDigests = [:]
            case "path" where recordKind == .file:
                size = attributes["size"].flatMap(Int64.init)
                modifiedAt = attributes["lastmodificationdate"]
            case "content": digestContainer = .content
            case "structure": digestContainer = .structure
            case "doppelganger":
                sourcePlanFingerprint = attributes["sourceplanfingerprint"]
                mediaVolumeIdentifier = attributes["volumeidentifier"]
            default:
                if algorithm(for: element) != nil, recordKind == .file {
                    hashDate = attributes["hashdate"] ?? hashDate
                    action = attributes["action"] ?? action
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let element = elementName.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if element == "file" || element == "path" { path = value }
            if element == "size" { size = Int64(value) }
            if element == "hashdate" { hashDate = value }
            if element == "creationdate", recordKind == .none { creationDate = value }
            if let algorithm = algorithm(for: element), !value.isEmpty {
                switch recordKind {
                case .file: digests[algorithm] = value.lowercased()
                case .directory, .root:
                    switch digestContainer {
                    case .content: contentDigests[algorithm] = value.lowercased()
                    case .structure: structureDigests[algorithm] = value.lowercased()
                    case .none: break
                    }
                case .none: break
                }
            }
            switch element {
            case "content", "structure": digestContainer = .none
            case "hash":
                if let path, let size, !digests.isEmpty {
                    entries.append(MHLDocument.Entry(
                        relativePath: path,
                        size: size,
                        digests: digests,
                        hashDate: hashDate,
                        modifiedAt: modifiedAt,
                        action: action
                    ))
                }
                recordKind = .none
            case "directoryhash":
                if let path {
                    directories.append(MHLDocument.DirectoryEntry(
                        relativePath: path,
                        contentDigests: contentDigests,
                        structureDigests: structureDigests
                    ))
                }
                recordKind = .none
            case "roothash":
                rootContentDigests = contentDigests
                rootStructureDigests = structureDigests
                recordKind = .none
            default: break
            }
            text = ""
        }

        private func algorithm(for element: String) -> ChecksumAlgorithm? {
            switch element {
            case "xxh3": .xxh3
            case "xxh64", "xxhash64be", "xxh64be": .xxh64
            case "md5": .md5
            default: nil
            }
        }
    }

    private final class ChainParserDelegate: NSObject, XMLParserDelegate {
        var entries: [MHLChainDocument.Entry] = []
        private var sequence: Int?
        private var path: String?
        private var c4: String?
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String] = [:]
        ) {
            text = ""
            if elementName.lowercased() == "hashlist" {
                sequence = attributes["sequencenr"].flatMap(Int.init)
                path = nil
                c4 = nil
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName.lowercased() {
            case "path": path = value
            case "c4": c4 = value
            case "hashlist":
                if let sequence, let path, let c4 {
                    entries.append(MHLChainDocument.Entry(sequence: sequence, path: path, c4: c4))
                }
            default: break
            }
            text = ""
        }
    }
}

public enum MHLReadError: LocalizedError {
    case invalidDocument
    case noHashes
    case inconsistentAlgorithms
    case invalidChain
    case chainDigestMismatch(path: String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "The MHL XML is not valid."
        case .noHashes: "The MHL contains no supported file hashes."
        case .inconsistentAlgorithms: "The MHL does not provide one supported algorithm for every file."
        case .invalidChain: "The ASC MHL chain is missing, malformed, or has a broken sequence."
        case .chainDigestMismatch(let path): "The ASC MHL chain checksum does not match \(path)."
        }
    }
}
