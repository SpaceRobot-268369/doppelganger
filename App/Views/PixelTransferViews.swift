import SwiftUI

// The pixel language for data in motion. Packets of pixels travel each
// source→destination connector while bytes move, and every destination tile
// carries a mosaic in which each cell is an equal slice of the plan's bytes.
// Colour follows the product semantics: blue copying, cyan read-back
// verification, yellow Fast pending, red failed, and green only once the
// whole transfer verified. Motion means bytes moved moments ago, never
// success: it stops at a terminal state, on a destination with nothing left to
// do, and during a stall; Reduce Motion replaces it with still pixels.

// MARK: - Mosaic model

/// The pass currently moving bytes through a destination, if any.
enum PixelPass: Sendable {
    /// Copying: bytes leave the source for the destination.
    case copy
    /// Verifying: the destination is read back and hashed.
    case readBack
}

/// What one mosaic cell shows. Cases are ranked by how strongly they must
/// show: a cell that covers several files takes the most serious of them, so
/// a small failed file is never painted over by its verified neighbours.
enum PixelCell: Int, Comparable, Sendable {
    /// The destination verified end to end in a verified transfer.
    case confirmed
    /// This file verified, but the transfer as a whole did not.
    case verifiedFile
    /// Read back and matched while the run is still live.
    case readBack
    /// Written, not yet read back.
    case copied
    /// Fast profile: transferred, never read back.
    case pendingVerification
    /// Not reached, skipped, or never attempted.
    case empty
    case failed

    static func < (lhs: PixelCell, rhs: PixelCell) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A destination's mosaic, as spans over the plan's bytes (0 = first byte,
/// 1 = last). Live, the engine reports byte counters rather than positions, so
/// the fill is a fraction and a failure sits where its pass was when it
/// happened. Once terminal, the report gives each file's exact range and
/// outcome.
struct PixelMosaicSnapshot: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var start: Double
        var end: Double
        var cell: PixelCell
    }

    var spans: [Span]
    /// Where the moving read/write head is while a pass is live.
    var head: Double?
    var headCell: PixelCell = .copied
    /// When the head's bytes last moved. The head only blinks while that is
    /// recent; a stalled or finished pass leaves it still.
    var headLastAdvance: Date?

    static let empty = PixelMosaicSnapshot(spans: [], head: nil)

    /// Every file failed at this destination while the run is still live — a
    /// destination refused before the copy began. Shown as it will end.
    static let allFailed = PixelMosaicSnapshot(spans: [Span(start: 0, end: 1, cell: .failed)], head: nil)

    /// A pass in progress. The unreached remainder is an explicit empty span,
    /// so a boundary cell takes the less finished state and never shows done
    /// before all of its bytes are.
    static func live(
        copied: Double,
        verified: Double,
        pass: PixelPass?,
        failureMarks: [Double] = [],
        lastAdvance: Date? = nil
    ) -> PixelMosaicSnapshot {
        let copied = clamp(copied)
        let verified = clamp(verified)
        var spans: [Span] = []
        if verified > 0 {
            spans.append(Span(start: 0, end: verified, cell: .readBack))
        }
        if copied > verified {
            spans.append(Span(start: verified, end: copied, cell: .copied))
        }
        let reached = max(copied, verified)
        if reached < 1 {
            spans.append(Span(start: reached, end: 1, cell: .empty))
        }
        spans += failureMarks.map { Span(start: clamp($0), end: clamp($0), cell: .failed) }
        switch pass {
        case .copy where copied < 1:
            return PixelMosaicSnapshot(
                spans: spans, head: copied, headCell: .copied, headLastAdvance: lastAdvance)
        case .readBack where verified < 1:
            return PixelMosaicSnapshot(
                spans: spans, head: verified, headCell: .readBack, headLastAdvance: lastAdvance)
        default:
            return PixelMosaicSnapshot(spans: spans, head: nil)
        }
    }

    /// The exact picture of a finished run: each item covers its share of the
    /// plan's bytes, in plan order, with its outcome at this destination.
    static func terminal(
        items: [(size: Int64, outcome: ItemDestinationOutcome?)],
        transferVerified: Bool
    ) -> PixelMosaicSnapshot {
        let total = items.reduce(Int64(0)) { $0 + max($1.size, 0) }
        // An all-empty plan still gets one equal slice per item.
        let weight: (Int64) -> Double = total > 0
            ? { Double(max($0, 0)) / Double(total) }
            : { _ in 1 / Double(max(items.count, 1)) }
        var spans: [Span] = []
        var position = 0.0
        for item in items {
            let end = min(position + weight(item.size), 1)
            let cell = cell(for: item.outcome, transferVerified: transferVerified)
            if let last = spans.last, last.cell == cell, last.end == position, last.end > last.start {
                spans[spans.count - 1].end = end
            } else {
                spans.append(Span(start: position, end: end, cell: cell))
            }
            position = end
        }
        return PixelMosaicSnapshot(spans: spans, head: nil)
    }

    /// One continuous fill, for a single-row overall meter.
    static func progress(
        fraction: Double,
        cell: PixelCell,
        live: Bool,
        lastAdvance: Date? = nil
    ) -> PixelMosaicSnapshot {
        let fraction = clamp(fraction)
        var spans: [Span] = []
        if fraction > 0 { spans.append(Span(start: 0, end: fraction, cell: cell)) }
        if fraction < 1 { spans.append(Span(start: fraction, end: 1, cell: .empty)) }
        return PixelMosaicSnapshot(
            spans: spans,
            head: live && fraction < 1 ? fraction : nil,
            headCell: cell,
            headLastAdvance: lastAdvance
        )
    }

    /// Resolves every cell of a `count`-cell grid, first byte first. Each span
    /// touches only the cells it overlaps, so this stays linear in spans plus
    /// cells even for plans of many thousands of files.
    func cells(count: Int) -> [PixelCell] {
        guard count > 0 else { return [] }
        let n = Double(count)
        let epsilon = 1e-9
        var resolved = [PixelCell?](repeating: nil, count: count)
        for span in spans {
            // Every span owns at least the cell its start falls in — a point
            // (a zero-byte file, a live failure mark) or a sliver of a file on
            // a cell boundary included — so no failure falls between cells.
            let first = min(max(Int((span.start * n + epsilon).rounded(.down)), 0), count - 1)
            let last = span.end <= span.start
                ? first
                : min(max(Int((span.end * n - epsilon).rounded(.up)) - 1, first), count - 1)
            for index in first...last {
                resolved[index] = max(resolved[index] ?? span.cell, span.cell)
            }
        }
        return resolved.map { $0 ?? .empty }
    }

    func headIndex(count: Int) -> Int? {
        guard count > 0, let head, head < 1 else { return nil }
        return min(max(Int((head * Double(count)).rounded(.down)), 0), count - 1)
    }

    /// Whether the head's pass moved bytes recently enough to show as live.
    func headIsMoving(at date: Date) -> Bool {
        head != nil && PixelActivityLog.isRecent(headLastAdvance, at: date)
    }

    private static func cell(for outcome: ItemDestinationOutcome?, transferVerified: Bool) -> PixelCell {
        switch outcome {
        case .verified, .verifiedDuplicate: transferVerified ? .confirmed : .verifiedFile
        case .transferredPendingVerification: .pendingVerification
        case .failed: .failed
        case .skipped, nil: .empty
        }
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

// MARK: - Live activity

/// What the session has seen of each destination's bytes while running: when
/// each pass last moved them, where each live failure happened, and how many
/// bytes were already in place before the copy began. Fed straight from the
/// engine's events, so it does not depend on which views are on screen.
struct PixelActivityLog: Equatable, Sendable {
    /// How long after its last byte a destination still shows as moving:
    /// long enough to bridge progress updates on a slow drive, short enough
    /// that a finished or stalled pass goes still promptly.
    static let activityWindow: TimeInterval = 4

    private(set) var lastCopyAdvance: [URL: Date] = [:]
    private(set) var lastReadBackAdvance: [URL: Date] = [:]
    /// Bytes already in place when the copy pass began: files a resumed
    /// attempt restored and files proven as verified duplicates. The live
    /// fill starts after them, where this pass actually writes.
    private(set) var settledBytes: [URL: Int64] = [:]
    private(set) var failureMarks: [URL: [Double]] = [:]
    private(set) var failureCounts: [URL: Int] = [:]

    /// Records which counters moved between two progress snapshots.
    /// `resumedBytes` is asked once per destination, the first time its copy
    /// pass is seen.
    mutating func noteProgress(
        from old: TransferProgress,
        to new: TransferProgress,
        at date: Date,
        destinations: [URL],
        resumedBytes: (URL) -> Int64
    ) {
        for destination in destinations {
            if (new.copiedBytesByDestination[destination] ?? 0)
                > (old.copiedBytesByDestination[destination] ?? 0) {
                lastCopyAdvance[destination] = date
            }
            if (new.verifiedBytesByDestination[destination] ?? 0)
                > (old.verifiedBytesByDestination[destination] ?? 0) {
                lastReadBackAdvance[destination] = date
            }
            if new.phase == .copying, settledBytes[destination] == nil {
                // Anything read back before the copy began was a duplicate
                // proof, not this pass's work.
                settledBytes[destination] = resumedBytes(destination)
                    + (new.verifiedBytesByDestination[destination] ?? 0)
            }
        }
    }

    /// Pins a failure at `position` in the destination's mosaic. A burst at
    /// one spot (a destination refused up front fails every file at once)
    /// keeps a single mark.
    mutating func noteFailure(at destination: URL, position: Double) {
        failureCounts[destination, default: 0] += 1
        if let last = failureMarks[destination]?.last, abs(last - position) < 1e-9 { return }
        failureMarks[destination, default: []].append(position)
    }

    func lastAdvance(_ destination: URL, pass: PixelPass) -> Date? {
        pass == .copy ? lastCopyAdvance[destination] : lastReadBackAdvance[destination]
    }

    static func isRecent(_ date: Date?, at now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) < activityWindow
    }
}

// MARK: - Mosaic view

/// A grid of square pixels, filled first byte first, column by column, so a
/// wide strip reads left to right like the flow into the destination. The
/// cell count follows the available width; the head cell blinks while its
/// pass is moving bytes, and stays lit under Reduce Motion.
struct PixelMosaicView: View {
    let snapshot: PixelMosaicSnapshot
    var rows = 3
    var cellSize: CGFloat = 4
    var gap: CGFloat = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    static func height(rows: Int, cellSize: CGFloat = 4, gap: CGFloat = 1) -> CGFloat {
        CGFloat(rows) * (cellSize + gap) - gap
    }

    var body: some View {
        let blinking = !reduceMotion && snapshot.head != nil
        TimelineView(.animation(minimumInterval: 0.5, paused: !blinking)) { timeline in
            let moving = snapshot.headIsMoving(at: timeline.date)
            let lit = !blinking || Int(timeline.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Canvas { context, size in
                draw(in: context, size: size, headMoving: moving, headLit: lit)
            }
        }
        .frame(height: Self.height(rows: rows, cellSize: cellSize, gap: gap))
        .accessibilityHidden(true)
    }

    private func draw(in context: GraphicsContext, size: CGSize, headMoving: Bool, headLit: Bool) {
        let pitch = cellSize + gap
        let columns = max(Int((size.width + gap) / pitch), 1)
        let count = columns * rows
        let cells = snapshot.cells(count: count)
        let head = headMoving ? snapshot.headIndex(count: count) : nil
        for (index, cell) in cells.enumerated() {
            let rect = CGRect(
                x: CGFloat(index / rows) * pitch,
                y: CGFloat(index % rows) * pitch,
                width: cellSize,
                height: cellSize
            )
            if index == head, cell != .failed {
                let color = PixelPalette.color(snapshot.headCell)
                context.fill(Path(rect), with: .color(color.opacity(headLit ? 1 : 0.35)))
            } else {
                context.fill(Path(rect), with: .color(PixelPalette.fill(cell, contrast: contrast)))
            }
        }
    }
}

/// A single row of pixels: the collapsed card's overall meter.
struct PixelProgressStrip: View {
    let fraction: Double
    let cell: PixelCell
    let live: Bool
    var lastAdvance: Date?

    var body: some View {
        PixelMosaicView(
            snapshot: .progress(fraction: fraction, cell: cell, live: live, lastAdvance: lastAdvance),
            rows: 1,
            cellSize: 3,
            gap: 1
        )
    }
}

enum PixelPalette {
    static func color(_ cell: PixelCell) -> Color {
        switch cell {
        case .confirmed, .verifiedFile: .green
        case .readBack: .cyan
        case .copied: .blue
        case .pendingVerification: .yellow
        case .empty: .secondary
        case .failed: .red
        }
    }

    static func fill(_ cell: PixelCell, contrast: ColorSchemeContrast) -> Color {
        let increased = contrast == .increased
        return switch cell {
        // A verified file in a transfer that did not verify must not read as
        // the quiet success treatment.
        case .verifiedFile: color(cell).opacity(increased ? 0.6 : 0.4)
        // Copied bytes still owe a read-back; held back a step so the cyan of
        // verification visibly lights them up.
        case .copied: color(cell).opacity(increased ? 0.85 : 0.65)
        case .empty: color(cell).opacity(increased ? 0.32 : 0.18)
        default: color(cell)
        }
    }
}

// MARK: - Stream model

/// Pixel packets on one connector. Speed comes in a few fixed tiers relative
/// to the fastest destination, so the bottleneck runs visibly slower; the
/// packet count stays fixed and `PixelStreamClock` carries each packet on from
/// where it is when the speed changes, so nothing jumps.
struct PixelFlow: Equatable, Sendable {
    /// Outbound while copying; toward the source while reading back.
    var pass: PixelPass?
    var tier: Int
    /// When this destination's bytes for `pass` last moved.
    var lastAdvance: Date?

    static let idle = PixelFlow(pass: nil, tier: 0)
    static let packetCount = 3

    init(pass: PixelPass?, tier: Int, lastAdvance: Date? = nil) {
        self.pass = pass
        self.tier = min(max(tier, 0), 2)
        self.lastAdvance = lastAdvance
    }

    /// `relativeRate` is this destination's throughput over the fastest
    /// destination's.
    init(pass: PixelPass, relativeRate: Double, lastAdvance: Date?) {
        let rate = relativeRate.isFinite ? relativeRate : 1
        self.init(pass: pass, tier: rate < 0.5 ? 0 : rate < 0.85 ? 1 : 2, lastAdvance: lastAdvance)
    }

    /// Connector traversals per second.
    var speed: Double { [0.35, 0.55, 0.8][tier] }

    /// Bytes for this pass moved recently. A finished, refused, paused or
    /// stalled destination is not moving, whatever the phase says.
    func isMoving(at date: Date) -> Bool {
        pass != nil && PixelActivityLog.isRecent(lastAdvance, at: date)
    }

    /// Packet positions along the curve for a travelled `phase` (in
    /// traversals): 0 = source, 1 = destination.
    func packetPositions(phase: Double) -> [Double] {
        guard let pass else { return [] }
        let count = Self.packetCount
        return (0..<count).map { packet in
            var t = (phase + Double(packet) / Double(count)).truncatingRemainder(dividingBy: 1)
            if t < 0 { t += 1 }
            return pass == .copy ? t : 1 - t
        }
    }

    /// Reduce Motion: still pixels that say "moving" without moving.
    var stillPositions: [Double] {
        pass == nil ? [] : [0.3, 0.5, 0.7]
    }
}

/// Integrates each connector's travelled phase over time, so a speed change
/// carries the packets on from where they are instead of re-deriving their
/// positions from the absolute clock. A render-time cache: nothing on screen
/// depends on it beyond packet placement.
@MainActor
final class PixelStreamClock {
    private struct Track {
        var speed: Double
        var phase: Double
        var time: TimeInterval
    }

    private var tracks: [Int: Track] = [:]

    func phase(for connector: Int, speed: Double, at time: TimeInterval) -> Double {
        guard let track = tracks[connector] else {
            // Each connector starts at its own offset so parallel lines do not
            // march in lockstep.
            let start = Double(connector) * 0.37
            tracks[connector] = Track(speed: speed, phase: start, time: time)
            return start
        }
        let current = (track.phase + max(time - track.time, 0) * track.speed)
            .truncatingRemainder(dividingBy: 1)
        // Rebase on a speed change, and now and then anyway so the phase never
        // accumulates precision loss over a long run.
        if track.speed != speed || time - track.time > 60 {
            tracks[connector] = Track(speed: speed, phase: current, time: time)
        }
        return current
    }
}
