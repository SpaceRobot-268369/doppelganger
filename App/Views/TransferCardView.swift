import AppKit
import SwiftUI

/// One row of the dashboard: header with live status, a source→destinations
/// flow graph with per-destination progress, big stats while running, and an
/// expandable detail section (current file, failures, log, actions).
struct TransferCardView: View {
    @Bindable var model: AppModel
    @Bindable var session: TransferSession
    let index: Int
    /// True for the first *running* session in creation order — the one the
    /// dashboard opens by itself. List position says nothing about that.
    var isFirstRunning = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var isEjecting = false
    @State private var ejectMessage: String?

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
            } else {
                collapsedSummary
            }
        }
        .padding(18)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        )
        .animation(.snappy, value: expanded)
        .onAppear {
            if isFirstRunning { expanded = true }
        }
        .onChange(of: isFirstRunning) {
            if isFirstRunning { expanded = true }
        }
        .onChange(of: session.report?.status) {
            // Only a clean verified result earns the compact row. Failed,
            // cancelled, paused, and pending-verification cards stay open —
            // that is exactly when the failure list and safety text matter.
            if session.report?.status == .verified { expanded = false }
        }
    }

    /// Compact cards keep several jobs visible while retaining topology and a
    /// truthful phase/result at a glance.
    private var collapsedSummary: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label(session.sourceName, systemImage: "sdcard")
                    .lineLimit(1)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)
                Text(session.destinationBases.map(\.lastPathComponent).joined(separator: " · "))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer()
                if session.isActive {
                    Text("\(Int(session.overallFraction * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if session.isActive {
                ProgressView(value: session.overallFraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(session.progress.phase == .verifying ? .cyan : .blue)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            StatusDot(color: statusDotColor, active: session.isRunning, reduceMotion: reduceMotion)
            OperatorAvatarView(
                profile: session.operatorProfile,
                avatarStore: model.productStore.avatars,
                size: 28
            )
            .help(L10n.format("Started by %@", session.operatorProfile.displayName))
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
                    session.pause()
                } label: {
                    Label(session.pauseRequested ? "Pausing…" : "Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.glass)
                .disabled(
                    session.pauseRequested
                        || (session.progress.phase != .copying
                            && session.progress.phase != .preReadingSource)
                )
                .help("Stop after the current complete file, then verify and record finished files")
                Button {
                    session.cancel()
                } label: {
                    Label(session.cancelRequested ? "Cancelling…" : "Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.glass)
                .tint(.red)
                .disabled(session.cancelRequested)
            } else if session.isQueued {
                Button { model.moveQueued(session, by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.glass)
                .help("Move earlier in the queue")
                Button { model.moveQueued(session, by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.glass)
                .help("Move later in the queue")
                Button { model.prioritizeQueued(session) } label: {
                    Label("Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .help("Move to the front of the queue")
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
                .accessibilityLabel("Remove transfer from list")
            }
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.glass)
            .accessibilityLabel(expanded ? "Collapse transfer details" : "Expand transfer details")
        }
    }

    private var headlineColor: Color {
        if session.headline.isProblem { return .red }
        if session.report?.status == .transferredPendingVerification { return .yellow }
        guard session.isRunning else { return .secondary }
        return session.progress.phase == .verifying ? .cyan : .blue
    }

    private var statusDotColor: Color {
        if session.headline.isProblem { return .red }
        if session.report?.status == .paused { return .blue }
        if session.report?.status == .transferredPendingVerification { return .yellow }
        if session.report?.status == .verified { return .green }
        return session.isRunning ? .blue : .secondary
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
        case .copying: return .copying
        case .verifying: return .verifying
        case .pendingVerification: return .pendingVerification
        case .paused: return .pending
        case .verified: return .verified
        case .transferNotVerified: return .problem
        case .failed: return .problem
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
                    Text(session.sourceName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if session.planTotalBytes > 0 {
                        Text("· \(Format.bytes(session.planTotalBytes))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                labeledValue(L10n.text("FILES"), session.planItemCount > 0 ? "\(session.planItemCount)" : "—")
                labeledValue(L10n.text("ID"), session.shortID.isEmpty ? "—" : session.shortID.uppercased())
            }
            Spacer(minLength: 0)
            openFolderButton(session.source, label: "Open source in Finder")
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The explicit "open this folder in Finder" affordance on source chips
    /// and destination tiles.
    private func openFolderButton(_ url: URL, label: String) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "folder")
                .padding(2)
                .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .help("Open \(url.path) in Finder")
        .accessibilityLabel(label)
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
                Text(session.baseDestination(for: destination).lastPathComponent)
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
            openFolderButton(destination, label: "Open destination output in Finder")
            trailingIndicator(state, for: destination)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            state == .failed ? Color.red.opacity(0.12) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func destinationCaption(_ destination: URL) -> String {
        var parts = [
            Format.bytes(session.planTotalBytes),
            "\(Int(session.destinationFraction(destination) * 100))%",
        ]
        if let free = session.availableBytesByDestination[destination] {
            parts.append(L10n.format("%@ free", Format.bytes(free)))
        }
        let rate = session.destinationThroughput(destination)
        if rate > 0 { parts.append(Format.rate(rate)) }
        if let eta = session.destinationETA(destination) { parts.append(Format.eta(eta)) }
        if session.isBottleneck(destination) { parts.append(L10n.text("bottleneck")) }
        return parts.joined(separator: " · ")
    }

    private func statusColor(_ state: TransferSession.DestinationState, errors: Int) -> Color {
        if errors > 0 || state == .failed { return .red }
        switch state {
        case .pending: return .secondary
        case .copying: return .blue
        case .verifying: return .cyan
        case .pendingVerification: return .yellow
        case .paused: return .blue
        case .verified: return .green
        case .transferNotVerified: return .red
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
        case .transferNotVerified:
            // Copies landed here, but the transfer did not verify: red, and
            // a different mark from a destination whose own pairs failed.
            Image(systemName: "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(.red)
        case .pendingVerification:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.yellow)
        case .paused:
            Image(systemName: "pause.circle")
                .font(.title2)
                .foregroundStyle(.blue)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.title2)
                .foregroundStyle(.red)
        case .pending, .copying, .verifying:
            ProgressRing(
                fraction: session.destinationFraction(destination),
                color: session.destinationErrorCount(destination) > 0
                    ? .red : state == .verifying ? .cyan : .blue
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
                statBlock(Format.rate(session.throughputBytesPerSecond), L10n.text("Transfer rate"))
            }
            if let eta = session.etaSeconds {
                statBlock(Format.eta(eta), L10n.text("ETA"))
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
                    Text(session.algorithm.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if session.isRunning, session.pauseRequested {
                // A pause lands at the next complete-file boundary, which on a
                // large clip can be minutes away; say what it is waiting on.
                Label(pausingText, systemImage: "pause.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }
            if !session.liveFailures.isEmpty {
                failureList
            }
            if let report = session.report, !report.issues.isEmpty {
                transferIssueList(report.issues, verified: report.status == .verified)
            }
            if let report = session.report, report.status == .verified {
                Label(verifiedSummary(report), systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            if session.report != nil, session.headline.isProblem {
                Label("Do not erase the source media.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let partialCleanupMessage = session.partialCleanupMessage {
                Text(partialCleanupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let ejectMessage {
                Text(ejectMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let contactSheetMessage = session.contactSheetMessage {
                Text(contactSheetMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if session.showLog {
                LogPanel(entries: session.logEntries)
            }
            actions
        }
    }

    private var pausingText: String {
        if let current = session.progress.currentRelativePath {
            return L10n.format(
                "Pausing after the current file finishes · %@",
                Format.middleTruncated(current, max: 70)
            )
        }
        return L10n.text("Pausing after the current file finishes")
    }

    private func verifiedSummary(_ report: TransferReport) -> String {
        report.destinations.count == 1
            ? L10n.format(
                "%lld files × 1 destination — every copy passed checksum verification.",
                Int64(report.items.count)
            )
            : L10n.format(
                "%lld files × %lld destinations — every copy passed checksum verification.",
                Int64(report.items.count), Int64(report.destinations.count)
            )
    }

    private var liveFailureCountText: String {
        session.liveFailures.count == 1
            ? L10n.text("1 failure")
            : L10n.format("%lld failures", Int64(session.liveFailures.count))
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(liveFailureCountText, systemImage: "exclamationmark.octagon.fill")
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
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.red.opacity(0.25)))
    }

    /// Transfer-level issues on a verified report are warnings (orange): the
    /// media verified, something optional or cosmetic did not. On any other
    /// verdict they are part of why the transfer is not verified (red).
    private func transferIssueList(_ issues: [String], verified: Bool) -> some View {
        let tone: Color = verified ? .orange : .red
        return VStack(alignment: .leading, spacing: 5) {
            Label(
                verified ? "Transfer-level warning" : "Transfer-level issue",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(tone)
            ForEach(issues, id: \.self) { issue in
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tone.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tone.opacity(0.22)))
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
                if session.report?.status == .verified {
                    Button {
                        if let url = session.contactSheetURL {
                            reveal(url)
                        } else {
                            Task { await model.generateContactSheet(for: session) }
                        }
                    } label: {
                        Label(
                            session.contactSheetURL == nil ? "Contact Sheet" : "Show Contact Sheet",
                            systemImage: "rectangle.grid.3x2"
                        )
                    }
                    .buttonStyle(.glass)
                    .disabled(session.contactSheetMessage == L10n.text("Generating contact sheet…"))
                    .help("Create an optional JPEG preview after verification")
                }
                if session.report?.status == .paused {
                    if model.continuation(of: session.id) == .open {
                        Button {
                            model.resume(session)
                        } label: {
                            Label("Resume", systemImage: "play.fill")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .help("Create a linked attempt and reuse only previously verified complete files")
                    } else {
                        continuedNote
                    }
                    // Resume refuses when a destination lost its paused record
                    // and points here: a fresh offload in a new folder.
                    retryAsNewOffloadMenu
                } else if session.report?.status != .verified {
                    let retryable = model.retryableFailedPairCount(for: session)
                    if retryable > 0 {
                        Button {
                            model.retryFailures(session)
                        } label: {
                            Label(
                                "Retry \(retryable) Failure\(retryable == 1 ? "" : "s")",
                                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                            )
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.blue)
                        .help("Create linked attempts for only the failed file/destination pairs")
                    } else if session.failedPairCount > 0 {
                        continuedNote
                    }
                    retryAsNewOffloadMenu
                    if session.isRecovered {
                        Button {
                            session.cleanupGeneratedPartials()
                        } label: {
                            Label("Clean Temporary Files", systemImage: "sparkles")
                        }
                        .buttonStyle(.glass)
                        .help("Removes only hidden staging files created by this interrupted transfer")
                    }
                } else if session.report?.status == .verified {
                    Menu {
                        ForEach(session.destinations, id: \.self) { destination in
                            Button(session.baseDestination(for: destination).lastPathComponent) {
                                model.beginCascade(from: session, source: destination)
                            }
                        }
                    } label: {
                        Label("Cascade…", systemImage: "arrow.triangle.branch")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .help("Use a verified destination as the source of a separately evidenced onward task")
                    sourceEjectControl
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

    /// A fresh reviewed offload of this attempt's task into a new folder; the
    /// folder this attempt wrote stays as it is.
    private var retryAsNewOffloadMenu: some View {
        Menu {
            Button("Retry as New Offload") {
                model.retryAsNewOffload(session)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .help("Open a reviewed preflight for a separate output folder")
    }

    /// Shown where Resume or Retry was: a linked attempt already continues
    /// this one, and that attempt's card carries the next action.
    private var continuedNote: some View {
        Label("Continued in a linked attempt", systemImage: "arrow.turn.down.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("A resume or repair attempt already continues this one. Use that attempt's card; continuing this one again would collide with the files it published.")
    }

    /// Offered only while the verified card itself is still mounted at its
    /// recorded mount point and no other queued or running transfer uses it.
    @ViewBuilder
    private var sourceEjectControl: some View {
        switch session.sourceEjectEligibility(among: model.sessions, mounted: model.volumeWatcher.volumes) {
        case .available:
            Button {
                ejectSource()
            } label: {
                Label(isEjecting ? "Ejecting…" : "Eject Source", systemImage: "eject.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
            .disabled(isEjecting)
            .help("Unmount and eject the verified source volume")
        case .inUse:
            // Orange means warning; the label carries the meaning, not colour alone.
            Button {} label: {
                Label("Source In Use", systemImage: "eject")
            }
            .buttonStyle(.glass)
            .tint(.orange)
            .disabled(true)
            .help("Another queued or running transfer still uses this source volume. Eject becomes available when it finishes.")
        case .notOffered, .identityUnverifiable, .sourceGone, .differentVolumeMounted:
            EmptyView()
        }
    }

    private func ejectSource() {
        isEjecting = true
        ejectMessage = nil
        Task {
            // Fresh mount state, then every check again. The unmount runs in
            // the same main-actor turn as the last check.
            model.volumeWatcher.refresh()
            let outcome = session.ejectSource(
                among: model.sessions,
                mounted: model.volumeWatcher.volumes
            ) { mountPoint in
                try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
            }
            ejectMessage = outcome.message
            isEjecting = false
        }
    }
}

// MARK: - Header decorations

/// The little live dot: solid when finished, with a soft radiating pulse
/// while the transfer is running. Under Reduce Motion the pulse becomes a
/// static halo — the colour and text carry the state, motion never does.
struct StatusDot: View {
    let color: Color
    let active: Bool
    var reduceMotion = false
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay {
                if active {
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1.5)
                        .scaleEffect(reduceMotion ? 1.6 : pulsing ? 2.6 : 1)
                        .opacity(reduceMotion ? 0.5 : pulsing ? 0 : 0.8)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// The equalizer decoration on active cards — pure ornament, driven by a
/// TimelineView so it needs no state.
struct ActivityBars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.12, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule()
                        .fill(.blue.opacity(0.75))
                        .frame(width: 2.5, height: reduceMotion
                            ? 6 : 3 + 11 * abs(sin(t * 2.3 + Double(i) * 0.9)))
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
    enum BadgeState: Equatable {
        case pending
        case copying
        case verifying
        case pendingVerification
        case verified
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
        case .copying: .blue.opacity(0.55)
        case .verifying: .cyan.opacity(0.6)
        case .pendingVerification: .yellow.opacity(0.7)
        case .verified: .green.opacity(0.55)
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
        let color: Color = switch state {
        case .pending: .secondary
        case .copying: .blue
        case .verifying: .cyan
        case .pendingVerification: .yellow
        case .verified: .green
        case .problem: .red
        }
        context.fill(circle, with: .color(color))
        if state == .verified || state == .problem || state == .pendingVerification {
            let symbolName = switch state {
            case .verified: "checkmark"
            case .pendingVerification: "clock"
            default: "xmark"
            }
            let symbol = Text(Image(systemName: symbolName))
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
            context.draw(symbol, at: point)
        } else {
            let inner = Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
            context.fill(inner, with: .color(.white))
        }
    }
}
