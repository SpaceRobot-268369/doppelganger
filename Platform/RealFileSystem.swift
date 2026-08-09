import Darwin
import Foundation

/// The production `FileSystemAccess`: real POSIX I/O against real paths.
/// Everything that touches an actual disk lives here, behind Core's protocol,
/// so the engine and its tests never depend on hardware.
public struct RealFileSystem: FileSystemAccess {
    public init() {}

    /// Regular files under `root`, relative paths preserved, sorted for
    /// determinism. Dot-prefixed files and directories (`.DS_Store`,
    /// `.Spotlight-V100`, `.fseventsd`, …) are index/metadata noise on camera
    /// cards and are skipped. Enumeration never writes anything under `root`.
    public func enumerate(root: URL) throws -> [SourceItem] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        let manager = FileManager()

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileSystemError.volumeGone
        }

        guard let enumerator = manager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FileSystemError.notReadable(detail: "\(rootPath): could not enumerate")
        }

        var items: [SourceItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(resolved.dropFirst(rootPath.count + 1))
            items.append(SourceItem(relativePath: relativePath, size: Int64(values?.fileSize ?? 0)))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager().fileExists(atPath: url.path)
    }

    public func createDirectory(at url: URL) throws {
        do {
            try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        } catch let error as NSError {
            // Surface the underlying POSIX code when there is one; the Cocoa
            // error code itself is not an errno.
            if let posix = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               posix.domain == NSPOSIXErrorDomain {
                throw IOContext.writing.map(Int32(posix.code), path: url.path)
            }
            throw FileSystemError.other(code: -1, detail: "\(url.path): \(error.localizedDescription)")
        }
    }

    public func openForReading(_ url: URL, uncached: Bool) throws -> any FileReadStream {
        try PosixReadStream(url: url, uncached: uncached)
    }

    public func openForWritingExclusive(_ url: URL) throws -> any FileWriteStream {
        try PosixWriteStream(url: url)
    }

    public func removeItem(at url: URL) throws {
        if unlink(url.path) != 0 {
            throw IOContext.writing.map(errno, path: url.path)
        }
    }

    public func freeSpace(at url: URL) throws -> Int64 {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else {
            throw IOContext.reading.map(errno, path: url.path)
        }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }
}
