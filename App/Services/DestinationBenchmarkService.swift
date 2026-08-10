import Foundation

struct DestinationBenchmarkResult: Codable, Hashable, Sendable {
    let path: String
    let writeBytesPerSecond: Double
    let readBytesPerSecond: Double
    let testedBytes: Int64
    let measuredAt: Date

    var bottleneckBytesPerSecond: Double {
        min(writeBytesPerSecond, readBytesPerSecond)
    }
}

enum DestinationBenchmarkService {
    /// Benchmarks only a disposable, uniquely named file inside the selected
    /// destination. The exact temporary file is removed on every exit path.
    static func run(at destination: URL, byteCount: Int = 32 * 1024 * 1024) async throws -> DestinationBenchmarkResult {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard manager.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let temporary = destination.appendingPathComponent(
                ".doppelganger-benchmark-\(UUID().uuidString.lowercased()).tmp"
            )
            defer { try? manager.removeItem(at: temporary) }

            guard manager.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let writeHandle = try FileHandle(forWritingTo: temporary)
            let block = Data(repeating: 0xD0, count: 1024 * 1024)
            let writeStarted = ContinuousClock.now
            var written = 0
            while written < byteCount {
                try Task.checkCancellation()
                let count = min(block.count, byteCount - written)
                try writeHandle.write(contentsOf: block.prefix(count))
                written += count
            }
            try writeHandle.synchronize()
            try writeHandle.close()
            let writeDuration = max(writeStarted.duration(to: .now).seconds, 0.000_001)

            let readHandle = try FileHandle(forReadingFrom: temporary)
            let readStarted = ContinuousClock.now
            var read = 0
            while true {
                try Task.checkCancellation()
                let data = try readHandle.read(upToCount: block.count) ?? Data()
                if data.isEmpty { break }
                read += data.count
            }
            try readHandle.close()
            let readDuration = max(readStarted.duration(to: .now).seconds, 0.000_001)

            return DestinationBenchmarkResult(
                path: destination.standardizedFileURL.path,
                writeBytesPerSecond: Double(written) / writeDuration,
                readBytesPerSecond: Double(read) / readDuration,
                testedBytes: Int64(byteCount),
                measuredAt: Date()
            )
        }.value
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
