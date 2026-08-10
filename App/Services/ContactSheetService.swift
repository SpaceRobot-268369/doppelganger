import AppKit
import Foundation
import QuickLookThumbnailing

enum ContactSheetError: LocalizedError {
    case noMedia
    case noThumbnails
    case encodingFailed

    var errorDescription: String? {
        let key = switch self {
        case .noMedia: "No files were available for a contact sheet."
        case .noThumbnails: "macOS could not render previews for the selected media."
        case .encodingFailed: "The contact sheet could not be encoded as JPEG."
        }
        return L10n.text(key)
    }
}

/// Optional, post-verification evidence aid. The transfer verdict never
/// depends on this service: it reads only a verified destination and writes a
/// uniquely named auxiliary JPEG beside the immutable evidence set.
enum ContactSheetService {
    private static let preferredExtensions: Set<String> = [
        "ari", "arx", "braw", "cin", "crm", "dng", "heic", "jpeg", "jpg",
        "m2ts", "mov", "mp4", "mts", "mxf", "png", "r3d", "tif", "tiff"
    ]

    static func fileName(shortID: String) -> String {
        "doppelganger-contact-sheet-\(shortID).jpg"
    }

    static func generate(report: TransferReport, label: String) async throws -> Data {
        guard report.status == .verified, let sourceRoot = report.destinations.first else {
            throw ContactSheetError.noMedia
        }
        let preferred = report.items.filter {
            preferredExtensions.contains(
                URL(fileURLWithPath: $0.item.relativePath).pathExtension.lowercased()
            )
        }
        let candidates = Array((preferred.isEmpty ? report.items : preferred).prefix(12))
        guard !candidates.isEmpty else { throw ContactSheetError.noMedia }

        var tiles: [(String, NSImage)] = []
        for item in candidates {
            let url = sourceRoot.appendingPathComponent(item.item.relativePath)
            if let image = await thumbnail(for: url) {
                tiles.append((item.item.relativePath, image))
            }
        }
        guard !tiles.isEmpty else { throw ContactSheetError.noThumbnails }
        return try await MainActor.run { try renderJPEG(tiles: tiles, label: label) }
    }

    static func write(_ data: Data, report: TransferReport) throws -> [URL] {
        let roots = report.destinations + report.manifestLocations.filter {
            !report.destinations.contains($0)
        }
        let fileSystem = RealFileSystem()
        var results: [URL] = []
        for root in roots {
            let target = root.appendingPathComponent(fileName(shortID: report.shortID))
            if fileSystem.fileExists(at: target) {
                results.append(target)
                continue
            }
            try fileSystem.createDirectory(at: root)
            let staging = root.appendingPathComponent(
                ".doppelganger-partial-\(report.shortID)-contact-sheet.jpg"
            )
            let stream = try fileSystem.openForWritingExclusive(staging)
            do {
                try stream.write(Array(data), count: data.count)
                try stream.close()
                try fileSystem.moveItemExclusive(from: staging, to: target)
                results.append(target)
            } catch {
                try? fileSystem.removeItem(at: staging)
                throw error
            }
        }
        return results
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 420, height: 260),
                scale: 2,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }

    @MainActor
    private static func renderJPEG(tiles: [(String, NSImage)], label: String) throws -> Data {
        let columns = 3
        let tileWidth: CGFloat = 420
        let tileHeight: CGFloat = 300
        let headerHeight: CGFloat = 92
        let rows = Int(ceil(Double(tiles.count) / Double(columns)))
        let size = NSSize(width: tileWidth * CGFloat(columns), height: headerHeight + tileHeight * CGFloat(rows))
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let title = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
        )
        title.draw(at: NSPoint(x: 28, y: size.height - 54))
        let subtitle = NSAttributedString(
            string: "Verified contact sheet · \(Date().formatted(date: .abbreviated, time: .shortened))",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        subtitle.draw(at: NSPoint(x: 30, y: size.height - 78))

        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = CGFloat(column) * tileWidth + 14
            let y = size.height - headerHeight - CGFloat(row + 1) * tileHeight + 14
            let imageRect = NSRect(x: x, y: y + 42, width: tileWidth - 28, height: tileHeight - 56)
            NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: tileWidth - 28, height: tileHeight - 14), xRadius: 12, yRadius: 12).fill()
            tile.1.draw(in: aspectFitRect(for: tile.1.size, inside: imageRect))
            let name = NSAttributedString(
                string: tile.0,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
            )
            name.draw(in: NSRect(x: x + 10, y: y + 12, width: tileWidth - 48, height: 20))
        }

        guard let tiff = canvas.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86])
        else { throw ContactSheetError.encodingFailed }
        return jpeg
    }

    private static func aspectFitRect(for source: NSSize, inside destination: NSRect) -> NSRect {
        guard source.width > 0, source.height > 0 else { return destination }
        let scale = min(destination.width / source.width, destination.height / source.height)
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        return NSRect(
            x: destination.midX - size.width / 2,
            y: destination.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
