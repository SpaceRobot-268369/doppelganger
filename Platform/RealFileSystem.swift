import Darwin
import Foundation

/// The production `FileSystemAccess`: real POSIX I/O against real paths.
/// Everything that touches an actual disk lives here, behind Core's protocol,
/// so the engine and its tests never depend on hardware.
public struct RealFileSystem: FileSystemAccess {
    public init() {}

    /// Regular files under `root`, relative paths preserved, sorted for
    /// determinism. Only known operating-system metadata is excluded; arbitrary
    /// hidden files are media unless the user explicitly configures otherwise.
    public func enumerate(root: URL) throws -> [SourceItem] {
        let resolvedRoot = canonicalURL(root)
        let rootPath = resolvedRoot.path
        let manager = FileManager()

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileSystemError.volumeGone
        }

        guard let enumerator = manager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            throw FileSystemError.notReadable(detail: "\(rootPath): could not enumerate")
        }

        var items: [SourceItem] = []
        for case let url as URL in enumerator {
            let relativeUnresolved = String(url.path.dropFirst(rootPath.count + 1))
            if Self.isKnownMetadata(relativeUnresolved) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(resolved.dropFirst(rootPath.count + 1))
            items.append(SourceItem(
                relativePath: relativePath,
                size: Int64(values?.fileSize ?? 0),
                modificationTime: values?.contentModificationDate?.timeIntervalSince1970
            ))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    public func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func volume(at url: URL) throws -> FileSystemVolume {
        var existing = url.standardizedFileURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: existing.path), existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeUUIDStringKey, .volumeNameKey,
            .volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey,
            .volumeSupportsCaseSensitiveNamesKey,
        ]
        let values = try existing.resourceValues(forKeys: keys)
        let mount = values.volume ?? existing
        let identifier = values.volumeUUIDString ?? canonicalURL(mount).path
        return FileSystemVolume(
            identifier: identifier,
            name: values.volumeName ?? mount.lastPathComponent,
            mountPath: mount.path,
            fileSystem: values.volumeLocalizedFormatDescription,
            availableBytes: values.volumeAvailableCapacityForImportantUsage,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            isRemovable: values.volumeIsRemovable ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            supportsCaseSensitiveNames: values.volumeSupportsCaseSensitiveNames,
            maximumNameBytes: Self.pathLimit(existing.path, key: _PC_NAME_MAX),
            maximumPathBytes: Self.pathLimit(existing.path, key: _PC_PATH_MAX)
        )
    }

    public func sourceItem(at url: URL, relativeTo root: URL) throws -> SourceItem {
        let canonicalRoot = canonicalURL(root)
        let canonicalItem = canonicalURL(url)
        guard canonicalItem.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FileSystemError.sourceChanged
        }
        let values = try canonicalItem.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        )
        guard values.isRegularFile == true else { throw FileSystemError.sourceChanged }
        return SourceItem(
            relativePath: String(canonicalItem.path.dropFirst(canonicalRoot.path.count + 1)),
            size: Int64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970
        )
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

    public func openForWritingExclusive(_ url: URL, durability: WriteDurability) throws -> any FileWriteStream {
        try PosixWriteStream(url: url, durability: durability)
    }

    public func moveItemExclusive(from staging: URL, to final: URL) throws {
        if renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, final.path, UInt32(RENAME_EXCL)) != 0 {
            throw IOContext.writing.map(errno, path: final.path)
        }
    }

    public func replaceGeneratedIndexAtomically(from staging: URL, to final: URL) throws {
        if rename(staging.path, final.path) != 0 {
            throw IOContext.writing.map(errno, path: final.path)
        }
    }

    public func setModificationTime(_ timeIntervalSince1970: TimeInterval, at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timeIntervalSince1970)],
                ofItemAtPath: url.path
            )
        } catch {
            throw FileSystemError.other(code: -1, detail: "Could not preserve timestamp at \(url.path): \(error.localizedDescription)")
        }
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

    private static func isKnownMetadata(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        return components.contains { component in
            component == ".DS_Store"
                || component == "ascmhl"
                || component == ".Spotlight-V100"
                || component == ".fseventsd"
                || component == ".Trashes"
                || component == ".TemporaryItems"
                || component.hasPrefix("._")
                || component.hasPrefix(".doppelganger-partial-")
                || component.hasPrefix("doppelganger-manifest-")
                || component.hasPrefix("doppelganger-report-")
                || component.hasPrefix("doppelganger-transfer-")
                || component.hasPrefix("doppelganger-contact-sheet-")
        }
    }

    private static func pathLimit(_ path: String, key: Int32) -> Int? {
        let value = pathconf(path, key)
        return value > 0 ? value : nil
    }
}
