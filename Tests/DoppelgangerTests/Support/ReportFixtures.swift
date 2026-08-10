import Foundation
@testable import Doppelganger

/// Canned `TransferReport`s for manifest and markdown tests. Fixed UUIDs and
/// dates so encoded output is byte-stable.
enum ReportFixtures {
    static let transferID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let started = Date(timeIntervalSince1970: 1_754_700_000)
    static let finished = Date(timeIntervalSince1970: 1_754_700_242.5)
    static let source = URL(fileURLWithPath: "/Volumes/CARD_A01")
    static let destinationA = URL(fileURLWithPath: "/Volumes/RAID/day01")
    static let destinationB = URL(fileURLWithPath: "/Volumes/Shuttle/day01")

    static func verifiedReport(destinations: [URL] = [destinationA, destinationB]) -> TransferReport {
        TransferReport(
            id: transferID,
            status: .verified,
            algorithm: .xxh64,
            sourceRoot: source,
            destinations: destinations,
            startedAt: started,
            finishedAt: finished,
            items: [
                ItemResult(
                    item: SourceItem(relativePath: "DCIM/100MEDIA/A001.MP4", size: 1_234_567),
                    sourceDigest: "0123456789abcdef",
                    outcomes: Dictionary(uniqueKeysWithValues: destinations.map { ($0, .verified) })
                ),
                ItemResult(
                    item: SourceItem(relativePath: "DCIM/100MEDIA/A002.MP4", size: 42),
                    sourceDigest: "fedcba9876543210",
                    outcomes: Dictionary(uniqueKeysWithValues: destinations.map { ($0, .verified) })
                ),
            ],
            manifestLocations: [destinationA, destinationB]
        )
    }

    static func failedReport() -> TransferReport {
        TransferReport(
            id: transferID,
            status: .failed,
            algorithm: .xxh64,
            sourceRoot: source,
            destinations: [destinationA, destinationB],
            startedAt: started,
            finishedAt: finished,
            items: [
                ItemResult(
                    item: SourceItem(relativePath: "DCIM/100MEDIA/A001.MP4", size: 1_234_567),
                    sourceDigest: "0123456789abcdef",
                    outcomes: [
                        destinationA: .verified,
                        destinationB: .failed(.checksumMismatch(expected: "0123456789abcdef", actual: "1111111111111111")),
                    ]
                ),
                ItemResult(
                    item: SourceItem(relativePath: "DCIM/100MEDIA/A002.MP4", size: 42),
                    sourceDigest: nil,
                    outcomes: [
                        destinationA: .failed(.sourceUnreadable(detail: "read failed: Input/output error")),
                        destinationB: .skipped(.destinationUnavailable),
                    ]
                ),
            ],
            manifestLocations: [destinationA]
        )
    }
}
