import Darwin
import Foundation
import IOKit

/// The production `FileSystemAccess`: real POSIX I/O against real paths.
/// Everything that touches an actual disk lives here, behind Core's protocol,
/// so the engine and its tests never depend on hardware.
public struct RealFileSystem: FileSystemAccess {
    public init() {}

    /// Regular files under `root`, relative paths preserved, sorted for
    /// determinism. Only known operating-system metadata is excluded; arbitrary
    /// hidden files are media unless the user explicitly configures otherwise.
    /// Preflight, the engine plan and the post-transfer rescan all treat this
    /// list as the complete source, so a scan that could not see the whole
    /// tree throws instead of returning a shorter list.
    public func enumerate(root: URL) throws -> [SourceItem] {
        let resolvedRoot = canonicalURL(root)
        let rootPath = resolvedRoot.path
        let manager = FileManager()

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileSystemError.volumeGone
        }

        // A folder FileManager cannot list (EACCES, EPERM, EIO) is reported
        // only here; without a handler its whole subtree vanishes silently.
        // The handler runs synchronously inside nextObject().
        var unreadable: [String] = []
        guard let enumerator = manager.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [],
            errorHandler: { url, error in
                if !Self.toleratesReadError(at: url.path, rootPath: rootPath) {
                    unreadable.append(Self.unreadableEntry(path: url.path, error: error))
                }
                return true // keep scanning so every unreadable folder is named
            }
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
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                )
            } catch {
                if !Self.toleratesReadError(at: url.path, rootPath: rootPath) {
                    unreadable.append(Self.unreadableEntry(path: url.path, error: error))
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(resolved.dropFirst(rootPath.count + 1))
            items.append(SourceItem(
                relativePath: relativePath,
                size: Int64(values.fileSize ?? 0),
                modificationTime: values.contentModificationDate?.timeIntervalSince1970
            ))
        }
        if !unreadable.isEmpty {
            // A card pulled mid-scan is a vanished volume, not a permissions problem.
            guard manager.fileExists(atPath: rootPath) else { throw FileSystemError.volumeGone }
            throw FileSystemError.notReadable(detail: Self.unreadableDetail(unreadable))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
    }

    /// macOS-private stores that exist only at a volume root and are kept
    /// unreadable to ordinary users. They never hold camera media, so a read
    /// error at or under one of them, directly beneath the scanned root, is
    /// handled exactly as before this check existed. The same name anywhere
    /// deeper is ordinary content and fails the scan.
    private static let rootLevelSystemStores: Set<String> = [
        ".DocumentRevisions-V100",
        ".HFS+ Private Directory Data\r",
        ".PKInstallSandboxManager",
        ".PKInstallSandboxManager-SystemSoftware",
    ]

    /// Read errors that leave no gap in the plan: at or under known metadata
    /// (excluded from every plan anyway) or under a root-level system store.
    /// The root itself, and anything outside it, never qualifies.
    private static func toleratesReadError(at path: String, rootPath: String) -> Bool {
        // FileManager can report an error URL through the `/private` firmlink
        // (`/private/var/…`) while the canonical root reads `/var/…`, or the
        // other way round; compare both spellings.
        let alternate = path.hasPrefix("/private/")
            ? String(path.dropFirst("/private".count))
            : "/private" + path
        guard let match = [path, alternate].first(where: { $0.hasPrefix(rootPath + "/") }) else {
            return false
        }
        let relativePath = String(match.dropFirst(rootPath.count + 1))
        let topLevel = String(relativePath.prefix { $0 != "/" })
        return isKnownMetadata(relativePath) || rootLevelSystemStores.contains(topLevel)
    }

    private static func unreadableEntry(path: String, error: any Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return "\(path): \(String(cString: strerror(Int32(truncatingIfNeeded: underlying.code))))"
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return "\(path): \(String(cString: strerror(Int32(truncatingIfNeeded: nsError.code))))"
        }
        return "\(path): \(nsError.localizedDescription)"
    }

    /// At most five paths, deduplicated, so a dying card stays legible.
    private static func unreadableDetail(_ entries: [String]) -> String {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0).inserted }
        let shown = unique.prefix(5).joined(separator: "; ")
        return unique.count > 5 ? "\(shown); and \(unique.count - 5) more" : shown
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
            maximumPathBytes: Self.pathLimit(existing.path, key: _PC_PATH_MAX),
            physicalDeviceIdentifier: Self.physicalDeviceIdentifier(forPath: existing.path)
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

    public func openForWritingExclusive(_ url: URL) throws -> any FileWriteStream {
        try PosixWriteStream(url: url)
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
                // A fine-grained retry sets the parent's failed bytes aside
                // under `<output>/.doppelganger-failed/<parent>/` (TransferWorker).
                // They are known-bad evidence, never media: a cascade must not
                // copy them onward and Verify Existing must not count them as
                // added files. Exact name only; look-alike hidden names stay media.
                || component == ".doppelganger-failed"
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

// MARK: - Physical device identity

extension RealFileSystem {
    /// The failure domain behind the volume holding `path`, or `nil` when it
    /// cannot be established. See `FileSystemVolume.physicalDeviceIdentifier`.
    static func physicalDeviceIdentifier(forPath path: String) -> String? {
        var stats = statfs()
        guard statfs(path, &stats) == 0 else { return nil }
        let mountedFrom = withUnsafeBytes(of: stats.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return physicalDeviceIdentifier(
            isLocal: stats.f_flags & UInt32(MNT_LOCAL) != 0,
            mountedFrom: mountedFrom,
            wholePhysicalDisk: wholePhysicalDisk(forBSDName:)
        )
    }

    /// Pure classification of one mount, testable without hardware. Local
    /// mounts name a `/dev` node and resolve to their whole physical disk;
    /// network mounts resolve to their server. Anything else is unknown.
    static func physicalDeviceIdentifier(
        isLocal: Bool,
        mountedFrom: String,
        wholePhysicalDisk: (String) -> String?
    ) -> String? {
        if isLocal {
            guard mountedFrom.hasPrefix("/dev/") else { return nil }
            return wholePhysicalDisk(String(mountedFrom.dropFirst("/dev/".count))).map { "disk:" + $0 }
        }
        return networkServer(mountedFrom: mountedFrom).map { "net:" + $0 }
    }

    /// The server of a network mount source, lowercased, without user name
    /// or port: `//user@NAS.local/Share` (smbfs, afpfs), `nas:/export`
    /// (nfs), `https://dav.example.com/x` (webdav). Never returns the user.
    static func networkServer(mountedFrom source: String) -> String? {
        var rest = Substring(source)
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
        } else if let scheme = rest.range(of: "://") {
            rest = rest[scheme.upperBound...]
        } else if let colon = rest.firstIndex(of: ":") {
            rest = rest[..<colon]
        } else {
            return nil
        }
        var host = String(rest.prefix { $0 != "/" })
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[...close])              // IPv6 literal
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])              // port
        }
        host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    /// The outermost whole-disk IOMedia above `bsdName` — for an APFS volume
    /// the disk holding its container's physical store, for a partition its
    /// disk — as `<bsd>@<registry entry ID>`, so a BSD name reused after a
    /// re-attach never aliases. `nil` for disk images and other virtual
    /// devices, whose real backing store IOKit cannot name.
    static func wholePhysicalDisk(forBSDName bsdName: String) -> String? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching) // consumes `matching`
        guard entry != IO_OBJECT_NULL else { return nil }
        var outermost: String?
        var virtualAboveOutermost = false
        while true {
            if IOObjectConformsTo(entry, "IOMedia") != 0,
               registryProperty(entry, "Whole") as? Bool == true,
               let name = registryProperty(entry, "BSD Name") as? String {
                var entryID: UInt64 = 0
                _ = IORegistryEntryGetRegistryEntryID(entry, &entryID)
                outermost = "\(name)@\(entryID)"
                // Only what sits above the physical disk decides virtuality;
                // APFS layers below it are irrelevant.
                virtualAboveOutermost = false
            } else if IOObjectConformsTo(entry, "AppleDiskImageDevice") != 0
                        || IOObjectConformsTo(entry, "IOHDIXHDDrive") != 0
                        || isVirtualInterconnect(entry) {
                virtualAboveOutermost = true
            }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard status == KERN_SUCCESS else { break }
            entry = parent
        }
        return virtualAboveOutermost ? nil : outermost
    }

    private static func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func isVirtualInterconnect(_ entry: io_registry_entry_t) -> Bool {
        let characteristics = registryProperty(entry, "Protocol Characteristics") as? [String: Any]
        return characteristics?["Physical Interconnect"] as? String == "Virtual Interface"
    }
}
