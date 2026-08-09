import Foundation

/// The written record of a transfer — the deliverable that outlives the app
/// session. It must record enough for someone else, with different software,
/// to re-verify the copy. Field set is a superset of what an ASC MHL writer
/// needs, so MHL output can be added later from the same data.
///
/// All fields are plain strings/numbers so the JSON is self-describing and the
/// encoding round-trips exactly.
public struct TransferManifest: Codable, Sendable, Equatable {
    public struct DestinationRecord: Codable, Sendable, Equatable {
        public var path: String
        public var verifiedCount: Int
        public var failedCount: Int
        public var skippedCount: Int
    }

    public struct ItemRecord: Codable, Sendable, Equatable {
        public struct Result: Codable, Sendable, Equatable {
            public var destination: String
            /// "verified" | "failed" | "skipped"
            public var status: String
            /// Machine-readable slug, present unless verified.
            public var reason: String?
            /// Human-readable elaboration, when there is one.
            public var detail: String?
            /// Only for checksum mismatches: what the destination actually held.
            public var actualDigest: String?
        }

        public var relativePath: String
        public var size: Int64
        /// Source digest in lowercase hex; absent if the source was never read.
        public var digest: String?
        public var results: [Result]
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var itemCount: Int
        public var totalBytes: Int64
        public var verifiedCount: Int
        public var failedCount: Int
        public var skippedCount: Int
    }

    public var schemaVersion: Int
    public var generator: String
    public var transferID: String
    /// "verified" | "failed" | "cancelled"
    public var status: String
    /// Hash algorithm for every digest in this file, e.g. "xxh64".
    public var algorithm: String
    public var sourceRoot: String
    public var destinations: [DestinationRecord]
    /// ISO 8601 with fractional seconds.
    public var startedAt: String
    public var finishedAt: String
    public var summary: Summary
    public var items: [ItemRecord]
}

extension TransferManifest {
    static let currentSchemaVersion = 1

    public init(report: TransferReport) {
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        var destinationRecords: [DestinationRecord] = []
        for destination in report.destinations {
            var verified = 0, failed = 0, skipped = 0
            for item in report.items {
                switch item.outcomes[destination] {
                case .verified: verified += 1
                case .failed: failed += 1
                case .skipped: skipped += 1
                case nil: break
                }
            }
            destinationRecords.append(DestinationRecord(
                path: destination.path,
                verifiedCount: verified,
                failedCount: failed,
                skippedCount: skipped
            ))
        }

        let itemRecords = report.items.map { item in
            ItemRecord(
                relativePath: item.item.relativePath,
                size: item.item.size,
                digest: item.sourceDigest,
                results: report.destinations.map { destination in
                    Self.result(for: item.outcomes[destination], destination: destination)
                }
            )
        }

        self.init(
            schemaVersion: Self.currentSchemaVersion,
            generator: "doppelganger",
            transferID: report.id.uuidString.lowercased(),
            status: report.status.rawValue,
            algorithm: report.algorithm.rawValue,
            sourceRoot: report.sourceRoot.path,
            destinations: destinationRecords,
            startedAt: report.startedAt.formatted(iso),
            finishedAt: report.finishedAt.formatted(iso),
            summary: Summary(
                itemCount: report.items.count,
                totalBytes: report.totalBytes,
                verifiedCount: report.verifiedCount,
                failedCount: report.failedCount,
                skippedCount: report.skippedCount
            ),
            items: itemRecords
        )
    }

    private static func result(for outcome: ItemDestinationOutcome?, destination: URL) -> ItemRecord.Result {
        switch outcome {
        case .verified:
            ItemRecord.Result(destination: destination.path, status: "verified")
        case .failed(let reason):
            ItemRecord.Result(
                destination: destination.path,
                status: "failed",
                reason: reason.slug,
                detail: reason.detail,
                actualDigest: {
                    if case .checksumMismatch(_, let actual) = reason { return actual }
                    return nil
                }()
            )
        case .skipped(let reason):
            ItemRecord.Result(destination: destination.path, status: "skipped", reason: reason.rawValue)
        case nil:
            // An item with no recorded outcome for a destination is a skip,
            // never an implicit success.
            ItemRecord.Result(destination: destination.path, status: "skipped", reason: ItemSkipReason.sourceUnavailable.rawValue)
        }
    }
}
