import Foundation
import Testing
@testable import Doppelganger

struct PixelMosaicTests {
    // MARK: Terminal map

    @Test func verifiedTransferIsGreenEndToEnd() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(100, .verified), (300, .verifiedDuplicate), (600, .verified)],
            transferVerified: true
        )
        #expect(snapshot.cells(count: 40).allSatisfy { $0 == .confirmed })
        #expect(snapshot.head == nil)
        #expect(snapshot.spans.count == 1, "adjacent spans with one state merge")
    }

    @Test func smallFailedFileStaysVisibleInPlace() {
        // A 1-byte failure in a 10 GB plan still owns the cell it falls in,
        // and its neighbours never paint over it.
        let gigabyte: Int64 = 1_000_000_000
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(4_530_000_000, .verified), (1, .failed(.checksumMismatch(expected: "a", actual: "b"))),
                    (10 * gigabyte - 4_530_000_000, .verified)],
            transferVerified: false
        )
        let cells = snapshot.cells(count: 100)
        #expect(cells.filter { $0 == .failed }.count == 1)
        #expect(cells.firstIndex(of: .failed) == 45)
        #expect(!cells.contains(.confirmed), "a failed transfer never gets the success treatment")
    }

    @Test func tinyFailedFileOnACellBoundaryStillOwnsACell() {
        // First item of a huge plan: starts exactly on boundary 0.
        let first = PixelMosaicSnapshot.terminal(
            items: [(1, .failed(.destinationFull)), (300_000_000_000, .verified)],
            transferVerified: false
        )
        #expect(first.cells(count: 240)[0] == .failed)
        // Centred on boundary k/n.
        let middle = PixelMosaicSnapshot.terminal(
            items: [(150_000_000_000, .verified), (2, .failed(.destinationFull)), (150_000_000_000, .verified)],
            transferVerified: false
        )
        #expect(middle.cells(count: 240).filter { $0 == .failed }.count == 1)
    }

    @Test func verifiedFilesInAFailedTransferAreNotConfirmed() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(50, .verified), (50, .failed(.destinationFull))],
            transferVerified: false
        )
        let cells = snapshot.cells(count: 10)
        #expect(cells[0..<5].allSatisfy { $0 == .verifiedFile })
        #expect(cells[5..<10].allSatisfy { $0 == .failed })
    }

    @Test func fastProfileShowsPendingVerification() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(10, .transferredPendingVerification), (10, .transferredPendingVerification)],
            transferVerified: false
        )
        #expect(snapshot.cells(count: 8).allSatisfy { $0 == .pendingVerification })
    }

    @Test func skippedAndMissingOutcomesAreEmpty() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(50, .verified), (25, .skipped(.paused)), (25, nil)],
            transferVerified: false
        )
        let cells = snapshot.cells(count: 4)
        #expect(cells == [.verifiedFile, .verifiedFile, .empty, .empty])
    }

    @Test func zeroWidthSpanStillOwnsACell() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(100, .verified), (0, .failed(.missingFile)), (100, .verified)],
            transferVerified: false
        )
        #expect(snapshot.cells(count: 20).filter { $0 == .failed }.count == 1)
    }

    @Test func emptyPlanWeightsItemsEqually() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(0, .verified), (0, .failed(.missingFile))],
            transferVerified: false
        )
        #expect(snapshot.cells(count: 4) == [.verifiedFile, .verifiedFile, .failed, .failed])
    }

    @Test func interruptedRunWithNoItemsIsAllEmpty() {
        let snapshot = PixelMosaicSnapshot.terminal(items: [], transferVerified: false)
        #expect(snapshot.cells(count: 12).allSatisfy { $0 == .empty })
    }

    @Test func boundaryCellTakesTheMoreSeriousState() {
        // 0.55 of the bytes verified, the rest failed: the shared cell is red.
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(55, .verified), (45, .failed(.destinationUnmounted))],
            transferVerified: false
        )
        let cells = snapshot.cells(count: 10)
        #expect(cells[5] == .failed)
        #expect(cells[4] == .verifiedFile)
    }

    @Test func manyFilesResolveIntoFewCells() {
        let items: [(size: Int64, outcome: ItemDestinationOutcome?)] = (0..<20_000).map { index in
            (Int64(1 + index % 7), index == 12_345
                ? ItemDestinationOutcome.failed(.checksumMismatch(expected: "x", actual: "y")) : .verified)
        }
        let cells = PixelMosaicSnapshot.terminal(items: items, transferVerified: false).cells(count: 300)
        #expect(cells.count == 300)
        #expect(cells.filter { $0 == .failed }.count == 1)
    }

    // MARK: Live fill

    @Test func copyingFillsConservativelyWithAHead() {
        let snapshot = PixelMosaicSnapshot.live(copied: 0.25, verified: 0, pass: .copy)
        let cells = snapshot.cells(count: 10)
        #expect(cells[0..<2].allSatisfy { $0 == .copied })
        #expect(cells[2] == .empty, "a partly written cell is not shown as written")
        #expect(snapshot.headIndex(count: 10) == 2)
        #expect(snapshot.headCell == .copied)
    }

    @Test func verifyingShowsReadBackAheadOfCopied() {
        let snapshot = PixelMosaicSnapshot.live(copied: 1, verified: 0.5, pass: .readBack)
        let cells = snapshot.cells(count: 10)
        #expect(cells[0..<5].allSatisfy { $0 == .readBack })
        #expect(cells[5..<10].allSatisfy { $0 == .copied })
        #expect(snapshot.headIndex(count: 10) == 5)
        #expect(snapshot.headCell == .readBack)
    }

    @Test func finishedPassHasNoHead() {
        #expect(PixelMosaicSnapshot.live(copied: 1, verified: 0, pass: .copy).head == nil)
        #expect(PixelMosaicSnapshot.live(copied: 1, verified: 1, pass: .readBack).head == nil)
        #expect(PixelMosaicSnapshot.live(copied: 0.4, verified: 0, pass: nil).head == nil)
    }

    @Test func headOnlyMovesWhileItsBytesRecentlyMoved() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let fresh = PixelMosaicSnapshot.live(copied: 0.4, verified: 0, pass: .copy, lastAdvance: now.addingTimeInterval(-1))
        let stale = PixelMosaicSnapshot.live(copied: 0.4, verified: 0, pass: .copy, lastAdvance: now.addingTimeInterval(-10))
        let never = PixelMosaicSnapshot.live(copied: 0.4, verified: 0, pass: .copy)
        #expect(fresh.headIsMoving(at: now))
        #expect(!stale.headIsMoving(at: now), "a stalled or finished pass leaves the head still")
        #expect(!never.headIsMoving(at: now), "a destination this pass never touched shows no head")
    }

    @Test func liveFailureMarkIsRed() {
        let snapshot = PixelMosaicSnapshot.live(copied: 0.8, verified: 0, pass: .copy, failureMarks: [0.33])
        let cells = snapshot.cells(count: 10)
        #expect(cells[3] == .failed)
        #expect(cells.filter { $0 == .failed }.count == 1)
    }

    @Test func refusedDestinationIsAllRedWhileLive() {
        #expect(PixelMosaicSnapshot.allFailed.cells(count: 30).allSatisfy { $0 == .failed })
        #expect(PixelMosaicSnapshot.allFailed.head == nil)
    }

    @Test func nonFiniteCountersClampToNothing() {
        let snapshot = PixelMosaicSnapshot.live(copied: .nan, verified: .infinity, pass: .copy)
        #expect(snapshot.cells(count: 6).allSatisfy { $0 == .empty })
        #expect(snapshot.headIndex(count: 6) == 0)
    }

    @Test func zeroCellsIsEmpty() {
        #expect(PixelMosaicSnapshot.live(copied: 0.5, verified: 0, pass: .copy).cells(count: 0).isEmpty)
    }

    // MARK: Overall strip

    @Test func progressStripFillsAndShowsAHeadOnlyWhileLive() {
        let live = PixelMosaicSnapshot.progress(fraction: 0.5, cell: .copied, live: true)
        #expect(live.cells(count: 4) == [.copied, .copied, .empty, .empty])
        #expect(live.headIndex(count: 4) == 2)
        #expect(PixelMosaicSnapshot.progress(fraction: 0.5, cell: .copied, live: false).head == nil)
        #expect(PixelMosaicSnapshot.progress(fraction: 0, cell: .copied, live: false).cells(count: 3)
            .allSatisfy { $0 == .empty })
    }

    @Test func severityRanking() {
        let ranked: [PixelCell] = [.confirmed, .verifiedFile, .readBack, .copied, .pendingVerification, .empty, .failed]
        #expect(ranked == ranked.sorted())
    }
}

struct PixelActivityLogTests {
    private let a = URL(fileURLWithPath: "/tmp/pixel-test/A/out", isDirectory: true)
    private let b = URL(fileURLWithPath: "/tmp/pixel-test/B/out", isDirectory: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    private func progress(
        _ phase: TransferPhase,
        copied: [URL: Int64] = [:],
        verified: [URL: Int64] = [:]
    ) -> TransferProgress {
        TransferProgress(phase: phase, copiedBytesByDestination: copied, verifiedBytesByDestination: verified)
    }

    @Test func onlyDestinationsWhoseCountersMovedAreActive() {
        var log = PixelActivityLog()
        log.noteProgress(
            from: progress(.copying, copied: [a: 10, b: 10]),
            to: progress(.copying, copied: [a: 20, b: 10]),
            at: t0, destinations: [a, b], resumedBytes: { _ in 0 })
        #expect(log.lastAdvance(a, pass: .copy) == t0)
        #expect(log.lastAdvance(b, pass: .copy) == nil, "a dead or refused destination never advances")
        #expect(log.lastAdvance(a, pass: .readBack) == nil)
    }

    @Test func readBackActivityIsTrackedSeparately() {
        var log = PixelActivityLog()
        log.noteProgress(
            from: progress(.verifying, copied: [a: 100], verified: [a: 10]),
            to: progress(.verifying, copied: [a: 100], verified: [a: 40]),
            at: t0, destinations: [a], resumedBytes: { _ in 0 })
        #expect(log.lastAdvance(a, pass: .readBack) == t0)
        #expect(log.lastAdvance(a, pass: .copy) == nil)
    }

    @Test func activityWindowExpires() {
        #expect(PixelActivityLog.isRecent(t0, at: t0.addingTimeInterval(1)))
        #expect(!PixelActivityLog.isRecent(t0, at: t0.addingTimeInterval(PixelActivityLog.activityWindow + 0.1)))
        #expect(!PixelActivityLog.isRecent(nil, at: t0))
    }

    @Test func settledBytesCountResumedAndDuplicateBytesOnce() {
        var log = PixelActivityLog()
        // Duplicate proofs read back 30 bytes before the copy began.
        log.noteProgress(
            from: progress(.enumerating),
            to: progress(.enumerating, verified: [a: 30]),
            at: t0, destinations: [a], resumedBytes: { _ in 50 })
        #expect(log.settledBytes[a] == nil, "nothing settles before the copy pass")
        log.noteProgress(
            from: progress(.copying, verified: [a: 30]),
            to: progress(.copying, copied: [a: 5], verified: [a: 30]),
            at: t0, destinations: [a], resumedBytes: { _ in 50 })
        #expect(log.settledBytes[a] == 80)
        // Later read-back does not move the settled prefix.
        log.noteProgress(
            from: progress(.verifying, copied: [a: 20], verified: [a: 30]),
            to: progress(.verifying, copied: [a: 20], verified: [a: 45]),
            at: t0, destinations: [a], resumedBytes: { _ in 999 })
        #expect(log.settledBytes[a] == 80)
    }

    @Test func failureBurstAtOneSpotKeepsOneMarkButCountsEveryFile() {
        var log = PixelActivityLog()
        for _ in 0..<500 { log.noteFailure(at: a, position: 0) }
        log.noteFailure(at: a, position: 0.4)
        #expect(log.failureMarks[a] == [0, 0.4])
        #expect(log.failureCounts[a] == 501)
        #expect(log.failureMarks[b] == nil)
    }
}

struct PixelFlowTests {
    @Test func idleFlowCarriesNoPackets() {
        #expect(PixelFlow.idle.packetPositions(phase: 12.3).isEmpty)
        #expect(PixelFlow.idle.stillPositions.isEmpty)
        #expect(!PixelFlow.idle.isMoving(at: Date()))
    }

    @Test func flowMovesOnlyWhileItsBytesDo() {
        let now = Date(timeIntervalSinceReferenceDate: 9_000)
        #expect(PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: now).isMoving(at: now))
        #expect(!PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: now.addingTimeInterval(-30)).isMoving(at: now))
        #expect(!PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: nil).isMoving(at: now))
    }

    @Test func packetsStayOnTheCurve() {
        let flow = PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: nil)
        for phase in stride(from: -2.0, through: 5.0, by: 0.37) {
            let positions = flow.packetPositions(phase: phase)
            #expect(positions.count == PixelFlow.packetCount)
            #expect(positions.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func readBackRunsTowardTheSource() {
        let outbound = PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: nil)
        let readBack = PixelFlow(pass: .readBack, relativeRate: 1, lastAdvance: nil)
        for (a, b) in zip(outbound.packetPositions(phase: 0.21), readBack.packetPositions(phase: 0.21)) {
            #expect(abs((a + b) - 1) < 1e-9)
        }
    }

    @Test func bottleneckGetsTheSlowTier() {
        #expect(PixelFlow(pass: .copy, relativeRate: 0.2, lastAdvance: nil).tier == 0)
        #expect(PixelFlow(pass: .copy, relativeRate: 0.7, lastAdvance: nil).tier == 1)
        #expect(PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: nil).tier == 2)
        #expect(PixelFlow(pass: .copy, relativeRate: .nan, lastAdvance: nil).tier == 2)
        #expect(PixelFlow(pass: .copy, relativeRate: 0.2, lastAdvance: nil).speed
            < PixelFlow(pass: .copy, relativeRate: 1, lastAdvance: nil).speed)
    }

    @Test func reduceMotionStillPixels() {
        #expect(PixelFlow(pass: .readBack, relativeRate: 1, lastAdvance: nil).stillPositions == [0.3, 0.5, 0.7])
    }

    @MainActor
    @Test func speedChangeCarriesPacketsOnWithoutAJump() {
        let clock = PixelStreamClock()
        let start = clock.phase(for: 0, speed: 0.8, at: 100)
        let beforeChange = clock.phase(for: 0, speed: 0.8, at: 100.5)
        #expect(abs(beforeChange - (start + 0.4).truncatingRemainder(dividingBy: 1)) < 1e-9)
        // The tier drops: the phase continues from where it was.
        let atChange = clock.phase(for: 0, speed: 0.35, at: 100.5)
        #expect(abs(atChange - beforeChange) < 1e-9)
        let after = clock.phase(for: 0, speed: 0.35, at: 101.5)
        #expect(abs(after - (atChange + 0.35).truncatingRemainder(dividingBy: 1)) < 1e-9)
        // Connectors start at different offsets.
        #expect(clock.phase(for: 1, speed: 0.8, at: 100) != clock.phase(for: 2, speed: 0.8, at: 100))
    }
}
