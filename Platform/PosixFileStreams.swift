import Darwin
import Foundation

/// Whether an errno arose reading or writing — the same code can mean
/// different things (EIO on a read is a bad sector; on a write, a dying
/// destination).
enum IOContext {
    case reading
    case writing

    func map(_ code: Int32, path: String) -> FileSystemError {
        switch (code, self) {
        case (ENOSPC, _), (EDQUOT, _):
            return .noSpace
        case (EEXIST, _):
            return .alreadyExists
        case (ESTALE, _):
            return .sourceChanged
        case (ENOENT, _), (ENODEV, _), (ENXIO, _), (ENOTCONN, _), (ETIMEDOUT, _):
            // The file or its volume vanished out from under us.
            return .volumeGone
        case (EACCES, .reading), (EPERM, .reading), (EIO, .reading):
            return .notReadable(detail: "\(path): \(Self.message(code))")
        case (EIO, .writing):
            return .volumeGone
        default:
            return .other(code: code, detail: "\(path): \(Self.message(code))")
        }
    }

    private static func message(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

final class PosixReadStream: FileReadStream {
    private var descriptor: Int32
    private let path: String

    init(url: URL, uncached: Bool) throws {
        path = url.path
        descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else {
            throw IOContext.reading.map(errno, path: path)
        }
        if uncached {
            // Bypass the unified buffer cache so verification re-reads come
            // from the disk, not from the cache the copy pass just filled.
            _ = fcntl(descriptor, F_NOCACHE, 1)
        }
    }

    func read(into buffer: inout [UInt8]) throws -> Int {
        guard descriptor >= 0 else {
            throw FileSystemError.other(code: EBADF, detail: "\(path): read after close")
        }
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw IOContext.reading.map(errno, path: path)
        }
    }

    func close() {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit {
        close()
    }
}

final class PosixWriteStream: FileWriteStream {
    private var descriptor: Int32
    private let path: String

    /// Exclusive create: an existing file at `url` throws
    /// `FileSystemError.alreadyExists` rather than being overwritten.
    init(url: URL) throws {
        path = url.path
        descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw IOContext.writing.map(errno, path: path)
        }
    }

    func write(_ buffer: [UInt8], count: Int) throws {
        guard descriptor >= 0 else {
            throw FileSystemError.other(code: EBADF, detail: "\(path): write after close")
        }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            throw IOContext.writing.map(written < 0 ? errno : EIO, path: path)
        }
    }

    func close() throws {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        if fsync(fd) != 0 {
            let code = errno
            _ = Darwin.close(fd)
            throw IOContext.writing.map(code, path: path)
        }
        if Darwin.close(fd) != 0 {
            throw IOContext.writing.map(errno, path: path)
        }
    }

    deinit {
        if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }
}
