import Foundation
import Testing
@testable import Doppelganger

struct PixelMosaicTests {
    // MARK: Terminal map

    @Test func verifiedTransferIsGreenEndToEnd() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(100, .verified), (300, .verifiedDuplicate), (600, .verified)],
            state: .verified
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
            state: .failed
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
            state: .failed
        )
        #expect(first.cells(count: 240)[0] == .failed)
        // Centred on boundary k/n.
        let middle = PixelMosaicSnapshot.terminal(
            items: [(150_000_000_000, .verified), (2, .failed(.destinationFull)), (150_000_000_000, .verified)],
            state: .failed
        )
        #expect(middle.cells(count: 240).filter { $0 == .failed }.count == 1)
    }

    @Test func verifiedFilesInAFailedTransferAreNotConfirmed() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(50, .verified), (50, .failed(.destinationFull))],
            state: .failed
        )
        let cells = snapshot.cells(count: 10)
        #expect(cells[0..<5].allSatisfy { $0 == .verifiedFile })
        #expect(cells[5..<10].allSatisfy { $0 == .failed })
    }

    @Test func fastProfileShowsPendingVerification() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(10, .transferredPendingVerification), (10, .transferredPendingVerification)],
            state: .pendingVerification
        )
        #expect(snapshot.cells(count: 8).allSatisfy { $0 == .pendingVerification })
    }

    @Test func skippedAndMissingOutcomesAreEmpty() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(50, .verified), (25, .skipped(.paused)), (25, nil)],
            state: .paused
        )
        let cells = snapshot.cells(count: 4)
        #expect(cells == [.verifiedFile, .verifiedFile, .empty, .empty])
    }

    @Test func zeroWidthSpanStillOwnsACell() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(100, .verified), (0, .failed(.missingFile)), (100, .verified)],
            state: .failed
        )
        #expect(snapshot.cells(count: 20).filter { $0 == .failed }.count == 1)
    }

    @Test func emptyPlanWeightsItemsEqually() {
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(0, .verified), (0, .failed(.missingFile))],
            state: .failed
        )
        #expect(snapshot.cells(count: 4) == [.verifiedFile, .verifiedFile, .failed, .failed])
    }

    @Test func interruptedRunWithNoItemsIsAllEmpty() {
        let snapshot = PixelMosaicSnapshot.terminal(items: [], state: .failed)
        #expect(snapshot.cells(count: 12).allSatisfy { $0 == .empty })
    }

    @Test func boundaryCellTakesTheMoreSeriousState() {
        // 0.55 of the bytes verified, the rest failed: the shared cell is red.
        let snapshot = PixelMosaicSnapshot.terminal(
            items: [(55, .verified), (45, .failed(.destinationUnmounted))],
            state: .failed
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
        let cells = PixelMosaicSnapshot.terminal(items: items, state: .failed).cells(count: 300)
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

    @Test func progressStripIsBlueOnlyWhileBytesAreWritten() {
        #expect(TransferSession.pixelStripCell(phase: .preReadingSource, profile: .maximum) == .readBack,
                "the source pre-read has written nothing yet")
        #expect(TransferSession.pixelStripCell(phase: .copying, profile: .maximum) == .copied)
        #expect(TransferSession.pixelStripCell(phase: .verifying, profile: .standard) == .readBack)
        #expect(TransferSession.pixelStripCell(phase: .verifying, profile: .fast) == .copied,
                "Fast compares metadata and reads nothing back")
    }

    @Test func severityRanking() {
        let ranked: [PixelCell] = [.confirmed, .verifiedFile, .readBack, .copied, .pendingVerification, .empty, .failed]
        #expect(ranked == ranked.sorted())
    }
}

/// The terminal mosaic is keyed on `TransferSession.terminalDestinationState`,
/// the state behind the tile's text and symbol, so its pixels never claim more
/// than the tile does: green only on a verified tile, yellow only where
/// verification is genuinely pending or a paused Fast attempt holds copies its
/// resume carries forward. No running `TransferSession` is constructed: its
/// init writes a journal under Application Support. A restored card is built
/// the way the app restores one, which never saves.
struct PixelTerminalTileTests {
    private static let destinationA = ReportFixtures.destinationA
    private static let destinationB = ReportFixtures.destinationB
    private static let spool = URL(fileURLWithPath: "/Volumes/Spool/aaaaaaaa", isDirectory: true)
    private static let pending = ItemDestinationOutcome.transferredPendingVerification
    private static let full = ItemDestinationOutcome.failed(.destinationFull)

    /// One 100-byte item per index; `a[i]` and `b[i]` are its outcomes.
    /// Evidence lands at both destinations and the spool unless stated.
    private static func report(
        _ status: TransferStatus,
        profile: VerificationProfile = .fast,
        a: [ItemDestinationOutcome],
        b: [ItemDestinationOutcome],
        evidenceAt manifestLocations: [URL]? = nil
    ) -> TransferReport {
        precondition(a.count == b.count, "one outcome per item at each destination")
        return TransferReport(
            id: ReportFixtures.transferID,
            status: status,
            algorithm: .xxh3,
            verificationProfile: profile,
            sourceRoot: ReportFixtures.source,
            destinations: [destinationA, destinationB],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: zip(a, b).enumerated().map { index, pair in
                ItemResult(
                    item: SourceItem(relativePath: "CLIP\(index).MOV", size: 100),
                    sourceDigest: "00",
                    outcomes: [destinationA: pair.0, destinationB: pair.1]
                )
            },
            manifestLocations: manifestLocations ?? [destinationA, destinationB, spool]
        )
    }

    private static func state(_ report: TransferReport, at destination: URL) -> TransferSession.DestinationState {
        TransferSession.terminalDestinationState(of: report, at: destination)
    }

    /// Twenty cells: with two equal items, ten per item.
    private static func cells(_ report: TransferReport, at destination: URL) -> [PixelCell] {
        TransferSession.terminalPixelMosaic(of: report, at: destination).cells(count: 20)
    }

    private static func halves(_ first: PixelCell, _ second: PixelCell) -> [PixelCell] {
        Array(repeating: first, count: 10) + Array(repeating: second, count: 10)
    }

    @Test func fastCopiesAreYellowOnlyWhereTheTileSaysPending() {
        // Evidence write failure, source re-scan veto, or Cancel while
        // finalizing: every Fast copy landed, and the tile is red.
        for status in [TransferStatus.failed, .cancelled] {
            let report = Self.report(status, a: [Self.pending, Self.pending], b: [Self.pending, Self.pending])
            #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
            #expect(Self.cells(report, at: Self.destinationA) == Self.halves(.copied, .copied), "\(status)")
        }
        // A destination whose own copy failed keeps its failure in place and
        // shows its landed copies unread.
        let ownFailure = Self.report(.failed, a: [Self.pending, Self.pending], b: [Self.pending, Self.full])
        #expect(Self.state(ownFailure, at: Self.destinationB) == .failed)
        #expect(Self.cells(ownFailure, at: Self.destinationB) == Self.halves(.copied, .failed))
        // The same copies under a genuinely pending verdict stay yellow.
        let genuine = Self.report(.transferredPendingVerification,
                                  a: [Self.pending, Self.pending], b: [.verifiedDuplicate, Self.pending])
        #expect(Self.cells(genuine, at: Self.destinationA) == Self.halves(.pendingVerification, .pendingVerification))
        #expect(Self.cells(genuine, at: Self.destinationB) == Self.halves(.verifiedFile, .pendingVerification))
        // A paused Fast attempt holds copies its resume carries forward.
        let paused = Self.report(.paused, a: [Self.pending, .skipped(.paused)], b: [Self.pending, .skipped(.paused)])
        #expect(Self.cells(paused, at: Self.destinationA) == Self.halves(.pendingVerification, .empty))
    }

    @Test func greenNeedsTheTileToSayVerified() {
        // Every copy verified, but the evidence never landed on B.
        let report = Self.report(.verified, profile: .standard,
                                 a: [.verified, .verifiedDuplicate], b: [.verified, .verified],
                                 evidenceAt: [Self.destinationA, Self.spool])
        #expect(Self.cells(report, at: Self.destinationA) == Self.halves(.confirmed, .confirmed))
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
        #expect(Self.cells(report, at: Self.destinationB) == Self.halves(.verifiedFile, .verifiedFile))
        // A refused MHL generation fails a run whose every copy verified.
        let failed = Self.report(.failed, profile: .standard, a: [.verified, .verified], b: [.verified, .verified])
        #expect(Self.cells(failed, at: Self.destinationA) == Self.halves(.verifiedFile, .verifiedFile))
    }

    /// The fail-closed invariant over every verdict, outcome mix and evidence
    /// placement: a confirmed cell needs a verified tile, a pending cell needs
    /// a pending or paused tile, and those tiles show every copy still owed a
    /// read-back as pending.
    @Test func terminalCellsNeverClaimMoreThanTheTile() {
        let outcomeSets: [[ItemDestinationOutcome]] = [
            [],
            [Self.pending, Self.pending],
            [.verifiedDuplicate, Self.pending],
            [.verified, .verified],
            [.verified, .verifiedDuplicate],
            [Self.pending, .skipped(.cancelled)],
            [Self.pending, .skipped(.paused)],
            [Self.pending, Self.full],
            [.verified, Self.full],
        ]
        let evidence: [[URL]] = [[Self.destinationA, Self.destinationB, Self.spool], [Self.spool], []]
        let statuses: [TransferStatus] = [.failed, .cancelled, .paused, .verified, .transferredPendingVerification]
        for status in statuses {
            for outcomes in outcomeSets {
                for locations in evidence {
                    let report = Self.report(status, a: outcomes, b: outcomes, evidenceAt: locations)
                    for destination in [Self.destinationA, Self.destinationB] {
                        let state = Self.state(report, at: destination)
                        let cells = Self.cells(report, at: destination)
                        let context = "\(status) · \(outcomes) · evidence at "
                            + "\(locations.map(\.lastPathComponent)) · \(state)"
                        #expect(!cells.contains(.confirmed) || state == .verified, "\(context)")
                        #expect(!cells.contains(.pendingVerification)
                            || state == .pendingVerification || state == .paused, "\(context)")
                        if state == .verified {
                            #expect(cells.allSatisfy { $0 == .confirmed }, "\(context)")
                        }
                        if state == .pendingVerification || state == .paused {
                            #expect(cells.contains(.pendingVerification) == outcomes.contains(Self.pending),
                                    "\(context)")
                        }
                    }
                }
            }
        }
    }

    /// A paused or Fast-pending attempt offered again after relaunch has its
    /// report and no engine behind it: no pass, no motion, and a mosaic keyed
    /// on its tile like any finished card.
    @MainActor
    @Test func aRestoredCardIsStillAndKeyedOnItsTile() {
        let paused = Self.report(.paused, a: [Self.pending, .skipped(.paused)], b: [Self.pending, .skipped(.paused)])
        // Defensive: a pending verdict whose evidence missed B.
        let pending = Self.report(.transferredPendingVerification,
                                  a: [Self.pending, Self.pending], b: [Self.pending, Self.pending],
                                  evidenceAt: [Self.destinationA, Self.spool])
        var restored: [TransferSession] = []
        for (report, status) in [(paused, TransferJournal.Status.paused), (pending, .transferredPendingVerification)] {
            let session = TransferSession(restoring: RestorableAttempt(
                journal: TransferJournal(
                    id: report.id,
                    label: "20261002_A001",
                    source: ReportFixtures.source,
                    destinationBases: [Self.destinationA, Self.destinationB],
                    destinations: [Self.destinationA, Self.destinationB],
                    algorithm: .xxh3,
                    verificationProfile: .fast,
                    allowSameVolume: true,
                    createdAt: ReportFixtures.started,
                    startedAt: ReportFixtures.started,
                    itemCount: report.items.count,
                    totalBytes: report.totalBytes,
                    status: status
                ),
                report: report
            ))
            #expect(session.pixelPass == nil)
            #expect(session.pixelLastAdvance == nil)
            #expect(session.pixelFlows() == [.idle, .idle])
            for destination in [Self.destinationA, Self.destinationB] {
                let mosaic = session.pixelMosaic(for: destination)
                #expect(mosaic == TransferSession.terminalPixelMosaic(of: report, at: destination))
                #expect(mosaic.head == nil)
                #expect(!mosaic.cells(count: 20).contains(.confirmed))
            }
            restored.append(session)
        }
        #expect(restored[0].pixelMosaic(for: Self.destinationA).cells(count: 20)
            == Self.halves(.pendingVerification, .empty))
        #expect(restored[1].pixelMosaic(for: Self.destinationA).cells(count: 20)
            == Self.halves(.pendingVerification, .pendingVerification))
        #expect(restored[1].pixelMosaic(for: Self.destinationB).cells(count: 20) == Self.halves(.copied, .copied))
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
