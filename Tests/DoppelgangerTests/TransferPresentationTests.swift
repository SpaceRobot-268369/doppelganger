import Foundation
import Testing
@testable import Doppelganger

/// The dashboard's derived presentation rules — fractions, attention, and the
/// sliding-window rate — exercised without a running engine or a session.
struct TransferPresentationTests {
    private static let destinationA = ReportFixtures.destinationA
    private static let destinationB = ReportFixtures.destinationB

    private static func report(
        status: TransferStatus,
        items: [(size: Int64, a: ItemDestinationOutcome, b: ItemDestinationOutcome)]
    ) -> TransferReport {
        TransferReport(
            id: ReportFixtures.transferID,
            status: status,
            algorithm: .xxh3,
            sourceRoot: ReportFixtures.source,
            destinations: [destinationA, destinationB],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: items.enumerated().map { index, entry in
                ItemResult(
                    item: SourceItem(relativePath: "CLIP\(index).MOV", size: entry.size),
                    sourceDigest: "00",
                    outcomes: [destinationA: entry.a, destinationB: entry.b]
                )
            },
            manifestLocations: []
        )
    }

    // MARK: - Terminal fractions

    @Test func pendingVerificationBytesCountTowardTheTerminalFraction() {
        let report = Self.report(status: .transferredPendingVerification, items: [
            (100, .transferredPendingVerification, .transferredPendingVerification),
            (300, .transferredPendingVerification, .transferredPendingVerification),
        ])
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationA) == 1)
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationB) == 1)
    }

    @Test func verifiedAndDuplicateBytesCountTowardTheTerminalFraction() {
        let report = Self.report(status: .verified, items: [
            (100, .verified, .verifiedDuplicate),
            (300, .verified, .verified),
        ])
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationA) == 1)
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationB) == 1)
    }

    @Test func failedDestinationKeepsItsVerifiedFractionOnly() {
        let report = Self.report(status: .failed, items: [
            (100, .verified, .verified),
            (300, .verified, .failed(.writeFailed(detail: "io"))),
            (600, .verified, .transferredPendingVerification),
        ])
        // The clean destination is fully landed.
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationA) == 1)
        // The failed destination shows only what verified — never 100%, and
        // pending bytes do not soften a failure.
        #expect(TransferSession.reportedFraction(of: report, at: Self.destinationB) == 0.1)
    }

    @Test func fractionIsZeroWhenNothingLandedOrTheReportIsEmpty() {
        let empty = Self.report(status: .cancelled, items: [])
        #expect(TransferSession.reportedFraction(of: empty, at: Self.destinationA) == 0)
        let skipped = Self.report(status: .cancelled, items: [
            (100, .skipped(.cancelled), .skipped(.cancelled)),
        ])
        #expect(TransferSession.reportedFraction(of: skipped, at: Self.destinationA) == 0)
    }

    // MARK: - Attention

    @Test func attentionIsFailedCancelledPendingOrLiveFailure() {
        #expect(TransferSession.needsAttention(liveFailureCount: 0, status: .failed))
        #expect(TransferSession.needsAttention(liveFailureCount: 0, status: .cancelled))
        #expect(TransferSession.needsAttention(liveFailureCount: 0, status: .transferredPendingVerification))
        #expect(TransferSession.needsAttention(liveFailureCount: 1, status: nil))
        #expect(TransferSession.needsAttention(liveFailureCount: 2, status: .verified))
    }

    @Test func pausedVerifiedAndCleanRunningAreNotAttention() {
        #expect(!TransferSession.needsAttention(liveFailureCount: 0, status: .paused))
        #expect(!TransferSession.needsAttention(liveFailureCount: 0, status: .verified))
        #expect(!TransferSession.needsAttention(liveFailureCount: 0, status: nil))
    }

    // MARK: - Sliding-window throughput

    @Test func windowedRateMeasuresOnlyTheRecentSamples() throws {
        // 10 MB/s for the first ten seconds, then a stall to 1 MB/s.
        var samples: [ThroughputSample] = []
        for second in 0...10 {
            samples.append(ThroughputSample(time: Double(second), bytes: Int64(second) * 10_000_000))
        }
        for second in 11...20 {
            samples.append(ThroughputSample(time: Double(second), bytes: 100_000_000 + Int64(second - 10) * 1_000_000))
        }
        let rate = try #require(ThroughputWindow.rate(samples: samples, now: 20, window: 5))
        // Reference is the sample at t = 15; cumulative would say 5.5 MB/s.
        #expect(rate == 1_000_000)
    }

    @Test func windowedRateUsesEverythingWhileTheTransferIsYoung() throws {
        let samples = [
            ThroughputSample(time: 0, bytes: 0),
            ThroughputSample(time: 1, bytes: 4_000_000),
            ThroughputSample(time: 2, bytes: 8_000_000),
        ]
        let rate = try #require(ThroughputWindow.rate(samples: samples, now: 2, window: 5))
        #expect(rate == 4_000_000)
    }

    @Test func rateDecaysWhenNoSampleHasArrivedRecently() throws {
        let samples = [
            ThroughputSample(time: 0, bytes: 0),
            ThroughputSample(time: 2, bytes: 8_000_000),
        ]
        // Rendered two seconds after the last sample, the same bytes are
        // spread over four seconds: a stalled copy does not keep its old rate.
        let rate = try #require(ThroughputWindow.rate(samples: samples, now: 4, window: 5))
        #expect(rate == 2_000_000)
    }

    @Test func fewerThanTwoSamplesFallsBackToTheCumulativeRate() {
        #expect(ThroughputWindow.rate(samples: [], now: 5) == nil)
        #expect(ThroughputWindow.rate(samples: [ThroughputSample(time: 1, bytes: 500)], now: 5) == nil)
        // Two samples at the same instant span no time either.
        let sameInstant = [ThroughputSample(time: 1, bytes: 0), ThroughputSample(time: 1, bytes: 500)]
        #expect(ThroughputWindow.rate(samples: sameInstant, now: 5) == nil)
    }

    @Test func rateNeverGoesNegative() {
        let samples = [ThroughputSample(time: 0, bytes: 900), ThroughputSample(time: 1, bytes: 100)]
        #expect(ThroughputWindow.rate(samples: samples, now: 1) == 0)
    }

    @Test func appendingKeepsTheWindowPlusOneReferenceSample() {
        var samples: [ThroughputSample] = []
        for second in 0...30 {
            samples = ThroughputWindow.appending(
                ThroughputSample(time: Double(second), bytes: Int64(second)),
                to: samples,
                now: Double(second),
                window: 5
            )
        }
        // Newest sample is t = 30; the window covers 25...30 and one older
        // reference sample (t = 25 is exactly the cutoff and is the reference).
        #expect(samples.first?.time == 25)
        #expect(samples.last?.time == 30)
        #expect(samples.count == 6)
        // And the retained ring still yields the right rate.
        #expect(ThroughputWindow.rate(samples: samples, now: 30, window: 5) == 1)
    }

    @Test func appendingCapsTheRingWhenSamplesArriveFasterThanTheWindow() {
        var samples: [ThroughputSample] = []
        for tick in 0..<1_000 {
            samples = ThroughputWindow.appending(
                ThroughputSample(time: Double(tick) / 1_000, bytes: Int64(tick)),
                to: samples,
                now: Double(tick) / 1_000,
                window: 5
            )
        }
        #expect(samples.count <= ThroughputWindow.maxSamples)
        #expect(samples.last?.bytes == 999)
    }
}
