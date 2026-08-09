import AppKit
import SwiftUI

/// One row of the dashboard: header with live status, a source→destinations
/// flow graph with per-destination progress, big stats while running, and an
/// expandable detail section (current file, failures, log, actions).
struct TransferCardView: View {
    @Bindable var model: AppModel
    @Bindable var session: TransferSession
    let index: Int

    @State private var expanded = true

    private static let tileHeight: CGFloat = 76
    private static let tileSpacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if expanded {
                flowGraph
                if session.isRunning {
                    statsCluster
                }
                detail
            } else if session.isRunning {
                collapsedProgress
            }
        }
        .padding(18)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .animation(.snappy, value: expanded)
    }

    /// Collapsed active cards keep a slim progress line so nothing looks stalled.
    private var collapsedProgress: some View {
        ProgressView(value: session.overallFraction)
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(.green)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            StatusDot(active: session.isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.title3.weight(.semibold))
                Text(session.headline.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(headlineColor)
            }
            Spacer()
            if session.isRunning {
                ActivityBars()
                Button {
                    session.cancel()
                } label: {
                    Label(session.cancelRequested ? "Cancelling…" : "Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(session.cancelRequested)
            } else if session.isQueued {
                Button {
                    model.withdraw(session)
                } label: {
                    Label("Remove", systemImage: "xmark")
                }
                .buttonStyle(.glass)
                .help("Take this transfer out of the queue")
            } else {
                Button {
                    model.remove(session)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .help("Remove from list (files and reports stay on disk)")
            }
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.glass)
        }
    }

    private var headlineColor: Color {
        if session.headline.isProblem { return .red }
        return session.isRunning ? .green : .secondary
    }

    // MARK: - Flow graph

    private var flowGraph: some View {
        HStack(alignment: .center, spacing: 0) {
            sourceChip
                .frame(width: 264)
            ConnectorView(
                states: session.destinations.map(badgeState(for:)),
                tileHeight: Self.tileHeight,
                tileSpacing: Self.tileSpacing
            )
            .frame(width: 56, height: destinationStackHeight)
            VStack(spacing: Self.tileSpacing) {
                ForEach(session.destinations, id: \.self) { destination in
                    destinationTile(destination)
                        .frame(height: Self.tileHeight)
                }
            }
        }
    }

    private var destinationStackHeight: CGFloat {
        let count = CGFloat(max(session.destinations.count, 1))
        return count * Self.tileHeight + (count - 1) * Self.tileSpacing
    }

    private func badgeState(for destination: URL) -> ConnectorView.BadgeState {
        if session.destinationErrorCount(destination) > 0 { return .problem }
        switch session.destinationState(destination) {
        case .pending: return .pending
        case .failed: return .problem
        case .copying, .verifying, .verified: return .ok
        }
    }

    private var sourceChip: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 48)
                .glassEffect(.regular, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if session.planTotalBytes > 0 {
                        Text("· \(Format.bytes(session.planTotalBytes))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                labeledValue("FILES", session.planItemCount > 0 ? "\(session.planItemCount)" : "—")
                labeledValue("ID", session.shortID.isEmpty ? "—" : session.shortID.uppercased())
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func destinationTile(_ destination: URL) -> some View {
        let state = session.destinationState(destination)
        let errors = session.destinationErrorCount(destination)
        return HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if session.planTotalBytes > 0 {
                    Text(destinationCaption(destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(session.destinationStatusText(destination))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(state, errors: errors))
            }
            .help(destination.path)
            Spacer(minLength: 8)
            trailingIndicator(state, for: destination)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(
            state == .failed ? .regular.tint(.red.opacity(0.2)) : .regular,
            in: .rect(cornerRadius: 14)
        )
    }

    private func destinationCaption(_ destination: URL) -> String {
        var caption = "\(Format.bytes(session.planTotalBytes)) · \(Int(session.destinationFraction(destination) * 100))%"
        if let free = Self.freeSpace(of: destination) {
            caption += " · \(Format.bytes(free)) free"
        }
        return caption
    }

    /// Live free space on the destination's volume — a cheap statfs, so it can
    /// ride along with progress updates.
    private static func freeSpace(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func statusColor(_ state: TransferSession.DestinationState, errors: Int) -> Color {
        if errors > 0 || state == .failed { return .red }
        switch state {
        case .pending: return .secondary
        case .copying, .verifying: return .green
        case .verified: return .green
        case .failed: return .red
        }
    }

    @ViewBuilder
    private func trailingIndicator(_ state: TransferSession.DestinationState, for destination: URL) -> some View {
        switch state {
        case .verified:
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.title2)
                .foregroundStyle(.red)
        case .pending, .copying, .verifying:
            ProgressRing(
                fraction: session.destinationFraction(destination),
                color: session.destinationErrorCount(destination) > 0 ? .red : .green
            )
            .frame(width: 26, height: 26)
        }
    }

    // MARK: - Stats

    private var statsCluster: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text("\(Int(session.overallFraction * 100))%")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(session.overallFraction * 100))
            if session.throughputBytesPerSecond > 0 {
                statBlock(Format.rate(session.throughputBytesPerSecond), "Transfer rate")
            }
            if let eta = session.etaSeconds {
                statBlock(Format.eta(eta), "ETA")
            }
            Spacer()
            if session.workBudgetBytes > 0 {
                Text("\(Format.bytes(session.doneBytes)) of \(Format.bytes(session.workBudgetBytes))")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statBlock(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if session.isRunning, let current = session.progress.currentRelativePath {
                HStack(spacing: 8) {
                    Text("Current file")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    Text(Format.middleTruncated(current, max: 70))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("XXH64")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if !session.liveFailures.isEmpty {
                failureList
            }
            if let report = session.report, report.status == .verified {
                Label(
                    "\(report.items.count) files × \(report.destinations.count) destination\(report.destinations.count == 1 ? "" : "s") — every copy passed checksum verification.",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.callout)
                .foregroundStyle(.green)
            }
            if session.report != nil, session.headline.isProblem {
                Label("Do not erase the source media.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if session.showLog {
                LogPanel(entries: session.logEntries)
            }
            actions
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(session.liveFailures.count) failure\(session.liveFailures.count == 1 ? "" : "s")",
                  systemImage: "exclamationmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            ForEach(Array(session.liveFailures.suffix(4).enumerated()), id: \.offset) { _, failure in
                Text("\(failure.relativePath) → \(failure.destination.lastPathComponent): \(failure.reason)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassEffect(.regular.tint(.red.opacity(0.22)), in: .rect(cornerRadius: 10))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $session.showLog) {
                Label("Log", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)
            if session.report != nil {
                Button {
                    reveal(session.markdownReportURL)
                } label: {
                    Label("Report", systemImage: "doc.richtext")
                }
                .buttonStyle(.glass)
                .disabled(session.markdownReportURL == nil)
                Button {
                    reveal(session.manifestURL)
                } label: {
                    Label("Manifest", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.glass)
                .disabled(session.manifestURL == nil)
                if let mhl = session.mhlURL {
                    Button {
                        reveal(mhl)
                    } label: {
                        Label("MHL", systemImage: "checkmark.seal.text.page")
                    }
                    .buttonStyle(.glass)
                }
            }
            Button {
                reveal(session.lastLogFileURL)
            } label: {
                Label("Log File", systemImage: "text.document")
            }
            .buttonStyle(.glass)
            .disabled(session.lastLogFileURL == nil)
            Spacer()
        }
    }

    private func reveal(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Header decorations

/// The little live dot: solid gray when finished, green with a soft radiating
/// pulse while the transfer is running.
struct StatusDot: View {
    let active: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .overlay {
                if active {
                    Circle()
                        .stroke(.green.opacity(0.6), lineWidth: 1.5)
                        .scaleEffect(pulsing ? 2.6 : 1)
                        .opacity(pulsing ? 0 : 0.8)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// The equalizer decoration on active cards — pure ornament, driven by a
/// TimelineView so it needs no state.
struct ActivityBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(.green.opacity(0.75))
                        .frame(width: 2.5, height: 3 + 11 * abs(sin(t * 2.3 + Double(i) * 0.9)))
                }
            }
        }
        .frame(width: 34, height: 16, alignment: .center)
        .accessibilityHidden(true)
    }
}

// MARK: - Progress ring

struct ProgressRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

// MARK: - Connector lines

/// Draws the curves from the source chip to each destination tile, with a
/// status badge riding each curve — green check while clean, red cross the
/// moment that destination has a failure.
struct ConnectorView: View {
    enum BadgeState {
        case pending
        case ok
        case problem
    }

    let states: [BadgeState]
    let tileHeight: CGFloat
    let tileSpacing: CGFloat

    var body: some View {
        Canvas { context, size in
            let start = CGPoint(x: 0, y: size.height / 2)
            for (index, state) in states.enumerated() {
                let end = CGPoint(x: size.width, y: centerY(index))
                var path = Path()
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: size.width * 0.55, y: start.y),
                    control2: CGPoint(x: size.width * 0.45, y: end.y)
                )
                context.stroke(
                    path,
                    with: .color(lineColor(state)),
                    style: StrokeStyle(lineWidth: 1.5)
                )
                drawBadge(context, state: state, at: midpoint(start: start, end: end, size: size))
            }
        }
    }

    private func centerY(_ index: Int) -> CGFloat {
        CGFloat(index) * (tileHeight + tileSpacing) + tileHeight / 2
    }

    /// Cubic Bézier point at t = 0.5 for the control points used above.
    private func midpoint(start: CGPoint, end: CGPoint, size: CGSize) -> CGPoint {
        let c1 = CGPoint(x: size.width * 0.55, y: start.y)
        let c2 = CGPoint(x: size.width * 0.45, y: end.y)
        let x = (start.x + 3 * c1.x + 3 * c2.x + end.x) / 8
        let y = (start.y + 3 * c1.y + 3 * c2.y + end.y) / 8
        return CGPoint(x: x, y: y)
    }

    private func lineColor(_ state: BadgeState) -> Color {
        switch state {
        case .pending: .secondary.opacity(0.3)
        case .ok: .green.opacity(0.55)
        case .problem: .red.opacity(0.6)
        }
    }

    private func drawBadge(_ context: GraphicsContext, state: BadgeState, at point: CGPoint) {
        guard state != .pending else { return }
        let radius: CGFloat = 8
        let circle = Path(ellipseIn: CGRect(
            x: point.x - radius, y: point.y - radius,
            width: radius * 2, height: radius * 2
        ))
        context.fill(circle, with: .color(state == .ok ? .green : .red))
        let symbol = Text(Image(systemName: state == .ok ? "checkmark" : "xmark"))
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
        context.draw(symbol, at: point)
    }
}
