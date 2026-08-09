import Foundation
import Testing
@testable import Doppelganger

struct ManifestTests {
    @Test func manifestRoundTripsThroughJSON() throws {
        let manifest = TransferManifest(report: ReportFixtures.failedReport())
        let data = try ManifestWriter.jsonData(for: manifest)
        let decoded = try ManifestWriter.decode(data)
        #expect(decoded == manifest)
    }

    @Test func encodingIsDeterministic() throws {
        let manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        let first = try ManifestWriter.jsonData(for: manifest)
        let second = try ManifestWriter.jsonData(for: manifest)
        #expect(first == second)
    }

    @Test func verifiedReportProducesVerifiedManifest() {
        let manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        #expect(manifest.status == "verified")
        #expect(manifest.algorithm == "xxh64")
        #expect(manifest.summary.itemCount == 2)
        #expect(manifest.summary.verifiedCount == 4)
        #expect(manifest.summary.failedCount == 0)
        #expect(manifest.summary.skippedCount == 0)
        #expect(manifest.destinations.count == 2)
        #expect(manifest.destinations.allSatisfy { $0.verifiedCount == 2 })
        // Destination order must match request order — the report renders and
        // an MHL writer will consume it in that order.
        #expect(manifest.destinations[0].path == ReportFixtures.destinationA.path)
        #expect(manifest.items[0].results[0].destination == ReportFixtures.destinationA.path)
    }

    @Test func failureStatesAreFullyRepresentable() throws {
        let manifest = TransferManifest(report: ReportFixtures.failedReport())
        #expect(manifest.status == "failed")
        #expect(manifest.summary.verifiedCount == 1)
        #expect(manifest.summary.failedCount == 2)
        #expect(manifest.summary.skippedCount == 1)

        let mismatch = manifest.items[0].results[1]
        #expect(mismatch.status == "failed")
        #expect(mismatch.reason == "checksum-mismatch")
        #expect(mismatch.actualDigest == "1111111111111111")

        let unreadable = manifest.items[1]
        #expect(unreadable.digest == nil)
        #expect(unreadable.results[0].reason == "source-unreadable")
        #expect(unreadable.results[0].detail?.contains("Input/output error") == true)
        #expect(unreadable.results[1].status == "skipped")
        #expect(unreadable.results[1].reason == "destination-unavailable")
    }

    @Test func timestampsAreISO8601WithFractionalSeconds() {
        let manifest = TransferManifest(report: ReportFixtures.verifiedReport())
        #expect(manifest.startedAt.hasSuffix("Z"))
        #expect(manifest.startedAt.contains("."))
        let parsed = try? Date(
            manifest.finishedAt,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
        #expect(parsed == ReportFixtures.finished)
    }

    @Test func generatedFileNamesUseTheShortID() {
        #expect(ManifestWriter.manifestFileName(shortID: "aaaaaaaa") == "doppelganger-manifest-aaaaaaaa.json")
        #expect(ManifestWriter.reportFileName(shortID: "aaaaaaaa") == "doppelganger-report-aaaaaaaa.md")
        #expect(ManifestWriter.logFileName(shortID: "aaaaaaaa") == "doppelganger-transfer-aaaaaaaa.log")
    }
}
