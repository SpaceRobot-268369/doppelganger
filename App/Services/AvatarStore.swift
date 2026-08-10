import AppKit
import Foundation

final class AvatarStore {
    private let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = base
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
                .appendingPathComponent("Avatars", isDirectory: true)
        }
    }

    func importImage(from source: URL, profileID: UUID) throws -> String {
        try importImageData(Data(contentsOf: source), profileID: profileID)
    }

    func importImageData(_ sourceData: Data, profileID: UUID) throws -> String {
        guard let image = NSImage(data: sourceData) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = NSSize(width: 256, height: 256)
        let output = NSImage(size: size)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let sourceSize = image.size
        let scale = max(size.width / max(sourceSize.width, 1), size.height / max(sourceSize.height, 1))
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let drawRect = NSRect(
            x: (size.width - drawSize.width) / 2,
            y: (size.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1)
        output.unlockFocus()

        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }

        let name = "\(profileID.uuidString.lowercased()).png"
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
        return name
    }

    func data(for fileName: String?) -> Data? {
        guard let url = url(for: fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    func url(for fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let candidate = root.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
