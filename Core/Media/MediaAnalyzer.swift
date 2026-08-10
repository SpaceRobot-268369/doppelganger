@preconcurrency import AVFoundation
import Foundation

public enum MediaHealthSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct MediaHealthFinding: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let severity: MediaHealthSeverity
    public let code: String
    public let message: String
    public let relativePath: String?

    public init(
        severity: MediaHealthSeverity,
        code: String,
        message: String,
        relativePath: String? = nil
    ) {
        self.id = "\(code):\(relativePath ?? "-")"
        self.severity = severity
        self.code = code
        self.message = message
        self.relativePath = relativePath
    }
}

public struct MediaClipMetadata: Codable, Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    public let relativePath: String
    public let durationSeconds: Double?
    public let width: Int?
    public let height: Int?
    public let codec: String?
    public let frameRate: Double?
    public let audioSampleRate: Double?
    public let cameraModel: String?
    public let creationDate: String?
}

public struct MediaAnalysisSummary: Codable, Hashable, Sendable {
    public let detectedFormats: [String]
    public let mediaFileCount: Int
    public let sidecarFileCount: Int
    public let clips: [MediaClipMetadata]
    public let findings: [MediaHealthFinding]
}

private struct CameraFormatDetector: Sendable {
    let name: String
    let detects: @Sendable (Set<String>, [String]) -> Bool
}

enum MediaAnalyzer {
    private static let mediaExtensions: Set<String> = [
        "ari", "arx", "braw", "crm", "mxf", "mov", "mp4", "mts", "m2ts",
        "r3d", "wav", "bwf", "aif", "aiff", "dng", "cin", "cdl"
    ]
    private static let sidecarExtensions: Set<String> = [
        "xml", "ale", "json", "csv", "xmp", "thm", "smi", "md5", "mhl"
    ]
    private static let probeExtensions: Set<String> = [
        "mxf", "mov", "mp4", "mts", "m2ts", "wav", "bwf", "aif", "aiff"
    ]

    /// Format support is data-driven: adding a camera family does not change
    /// the health engine or transfer plan.
    private static let detectors: [CameraFormatDetector] = [
        CameraFormatDetector(name: "ARRI") { extensions, _ in
            !extensions.isDisjoint(with: ["ari", "arx"])
        },
        CameraFormatDetector(name: "RED") { extensions, _ in extensions.contains("r3d") },
        CameraFormatDetector(name: "Blackmagic RAW") { extensions, _ in extensions.contains("braw") },
        CameraFormatDetector(name: "Canon Cinema RAW") { extensions, _ in extensions.contains("crm") },
        CameraFormatDetector(name: "Sony") { _, paths in
            paths.contains { $0.hasPrefix("xdroot/") || $0.hasPrefix("private/m4root/") }
        },
        CameraFormatDetector(name: "Canon") { _, paths in
            paths.contains { $0.hasPrefix("contents/clip/") || $0.contains("canon") }
        },
        CameraFormatDetector(name: "Codex") { _, paths in paths.contains { $0.contains("codex") } },
        CameraFormatDetector(name: "Production Audio") { extensions, _ in
            !extensions.isDisjoint(with: ["wav", "bwf"])
        },
    ]

    static func analyze(root: URL, items: [SourceItem]) async -> MediaAnalysisSummary {
        let lowerPaths = items.map { $0.relativePath.lowercased() }
        let extensions = lowerPaths.map { URL(fileURLWithPath: $0).pathExtension }
        let extensionSet = Set(extensions)
        var formats = detectors.filter { $0.detects(extensionSet, lowerPaths) }.map(\.name)
        if formats.isEmpty, !extensionSet.isDisjoint(with: mediaExtensions) {
            formats.append("Generic Media")
        }

        var findings: [MediaHealthFinding] = []
        findings.append(contentsOf: basicFindings(root: root, items: items))
        findings.append(contentsOf: orphanSidecarFindings(items: items))
        findings.append(contentsOf: sequenceFindings(items: items))
        findings.append(contentsOf: layoutFindings(formats: formats, lowerPaths: lowerPaths))

        let mediaCount = extensions.count { mediaExtensions.contains($0) }
        let sidecarCount = extensions.count { sidecarExtensions.contains($0) }
        if mediaCount == 0, !items.isEmpty {
            findings.append(MediaHealthFinding(
                severity: .info,
                code: "no-known-media",
                message: "No recognized camera or production-audio extensions were found. All reviewed files will still be copied."
            ))
        }
        let probeItems = items.filter {
            probeExtensions.contains(URL(fileURLWithPath: $0.relativePath).pathExtension.lowercased())
        }.prefix(24)
        var clips: [MediaClipMetadata] = []
        for item in probeItems {
            if let clip = await probe(root: root, item: item) { clips.append(clip) }
        }
        if mediaCount > clips.count, mediaCount > 0 {
            findings.append(MediaHealthFinding(
                severity: .info,
                code: "limited-metadata-support",
                message: "\(mediaCount - clips.count) media file(s) use formats for which AVFoundation exposes limited metadata; integrity verification is unaffected."
            ))
        }
        return MediaAnalysisSummary(
            detectedFormats: Array(Set(formats)).sorted(),
            mediaFileCount: mediaCount,
            sidecarFileCount: sidecarCount,
            clips: clips,
            findings: Array(Set(findings)).sorted { $0.id < $1.id }
        )
    }

    private static func basicFindings(root: URL, items: [SourceItem]) -> [MediaHealthFinding] {
        var findings: [MediaHealthFinding] = []
        let now = Date().timeIntervalSince1970
        for item in items {
            if item.size == 0 {
                findings.append(MediaHealthFinding(
                    severity: .error, code: "zero-byte", message: "File is empty.",
                    relativePath: item.relativePath
                ))
            }
            if let timestamp = item.modificationTime, timestamp > now + 86_400 {
                findings.append(MediaHealthFinding(
                    severity: .warning, code: "future-timestamp",
                    message: "Modification time is more than one day in the future.",
                    relativePath: item.relativePath
                ))
            }
            let url = root.appendingPathComponent(item.relativePath)
            do {
                let handle = try FileHandle(forReadingFrom: url)
                _ = try handle.read(upToCount: item.size > 0 ? 1 : 0)
                try handle.close()
            } catch {
                findings.append(MediaHealthFinding(
                    severity: .error, code: "unreadable",
                    message: "File could not be opened for reading: \(error.localizedDescription)",
                    relativePath: item.relativePath
                ))
            }
        }
        return findings
    }

    private static func orphanSidecarFindings(items: [SourceItem]) -> [MediaHealthFinding] {
        let mediaStems = Set(items.filter {
            mediaExtensions.contains(URL(fileURLWithPath: $0.relativePath).pathExtension.lowercased())
        }.map { stem($0.relativePath) })
        return items.compactMap { item in
            let ext = URL(fileURLWithPath: item.relativePath).pathExtension.lowercased()
            guard sidecarExtensions.contains(ext), !mediaStems.contains(stem(item.relativePath)) else { return nil }
            return MediaHealthFinding(
                severity: .warning,
                code: "orphan-sidecar",
                message: "Sidecar has no media file with the same base name.",
                relativePath: item.relativePath
            )
        }
    }

    private static func sequenceFindings(items: [SourceItem]) -> [MediaHealthFinding] {
        let regex = try? NSRegularExpression(pattern: #"^(.*?)(\d{3,})(\.[^.]+)$"#)
        var groups: [String: [(number: Int, path: String)]] = [:]
        for item in items {
            let ext = URL(fileURLWithPath: item.relativePath).pathExtension.lowercased()
            guard ["dng", "cin", "r3d", "ari"].contains(ext), let regex else { continue }
            let name = URL(fileURLWithPath: item.relativePath).lastPathComponent
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  let prefixRange = Range(match.range(at: 1), in: name),
                  let numberRange = Range(match.range(at: 2), in: name),
                  let number = Int(name[numberRange]) else { continue }
            let directory = (item.relativePath as NSString).deletingLastPathComponent.lowercased()
            let key = "\(directory)/\(name[prefixRange].lowercased()).\(ext)"
            groups[key, default: []].append((number, item.relativePath))
        }
        return groups.values.compactMap { entries in
            guard entries.count > 1 else { return nil }
            let numbers = entries.map(\.number).sorted()
            let missing = Set(numbers.first!...numbers.last!).subtracting(numbers)
            guard !missing.isEmpty else { return nil }
            return MediaHealthFinding(
                severity: .warning,
                code: "sequence-gap",
                message: "Sequence or split clip is missing segment(s): \(missing.sorted().prefix(12).map(String.init).joined(separator: ", ")).",
                relativePath: entries.sorted { $0.number < $1.number }.first?.path
            )
        }
    }

    private static func layoutFindings(formats: [String], lowerPaths: [String]) -> [MediaHealthFinding] {
        var findings: [MediaHealthFinding] = []
        if formats.contains("RED"), !lowerPaths.contains(where: { $0.contains(".rdc/") }) {
            findings.append(MediaHealthFinding(
                severity: .warning,
                code: "red-layout",
                message: "RED media was found outside a recognized .RDC card folder; verify the card structure."
            ))
        }
        if formats.count > 2 {
            findings.append(MediaHealthFinding(
                severity: .info,
                code: "mixed-formats",
                message: "Several camera/audio families share this source: \(formats.joined(separator: ", "))."
            ))
        }
        return findings
    }

    private static func probe(root: URL, item: SourceItem) async -> MediaClipMetadata? {
        let asset = AVURLAsset(url: root.appendingPathComponent(item.relativePath))
        let duration = (try? await asset.load(.duration))?.seconds
        let video = try? await asset.loadTracks(withMediaType: .video).first
        let audio = try? await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try? await video?.load(.naturalSize)
        let transform = try? await video?.load(.preferredTransform)
        let transformedSize: CGSize? = if let naturalSize, let transform {
            naturalSize.applying(transform)
        } else {
            naturalSize
        }
        let format = try? await video?.load(.formatDescriptions).first
        let subtype = format.map { CMFormatDescriptionGetMediaSubType($0) }
        let codec = subtype.map(fourCC)
        let audioDescription = try? await audio?.load(.formatDescriptions).first
        let audioRate = audioDescription.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
        }
        let commonMetadata = (try? await asset.load(.commonMetadata)) ?? []
        let quickTimeMetadata = (try? await asset.loadMetadata(for: .quickTimeMetadata)) ?? []
        let commonCameraModel = await metadataString(commonMetadata, containing: "model")
        let quickTimeCameraModel = await metadataString(quickTimeMetadata, containing: "model")
        let cameraModel = commonCameraModel ?? quickTimeCameraModel
        let creationDate = await metadataString(commonMetadata, containing: "creation")
        let frameRate = try? await video?.load(.nominalFrameRate)
        return MediaClipMetadata(
            relativePath: item.relativePath,
            durationSeconds: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            width: transformedSize.map { Int(abs($0.width).rounded()) }.flatMap { $0 > 0 ? $0 : nil },
            height: transformedSize.map { Int(abs($0.height).rounded()) }.flatMap { $0 > 0 ? $0 : nil },
            codec: codec,
            frameRate: frameRate.map(Double.init).flatMap { $0 > 0 ? $0 : nil },
            audioSampleRate: audioRate.flatMap { $0 > 0 ? $0 : nil },
            cameraModel: cameraModel,
            creationDate: creationDate
        )
    }

    private static func metadataString(_ items: [AVMetadataItem], containing needle: String) async -> String? {
        for item in items where
            item.commonKey?.rawValue.lowercased().contains(needle) == true
                || String(describing: item.identifier).lowercased().contains(needle) {
            if let value = try? await item.load(.stringValue) { return value }
        }
        return nil
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        let text = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? String(format: "0x%08x", value) : text
    }

    private static func stem(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingPathExtension().path.lowercased()
    }
}
