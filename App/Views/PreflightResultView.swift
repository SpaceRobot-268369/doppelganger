import SwiftUI

/// One reviewed source's preflight verdict. Everything that decides whether the
/// offload may start — issues, warnings, exact output paths, and the
/// same-volume acknowledgement — stays visible; the supporting detail folds
/// away so the sheet reads as a decision, not a report.
struct PreflightResultView: View {
    @Bindable var model: AppModel
    let result: TransferPreflight
    let showsSourceName: Bool
    @Binding var warningsAcknowledged: Bool

    @State private var showingTree = false
    @State private var showingMedia = false
    @State private var showingHistory = false
    @State private var tree: [SourceTreeNode] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headline
            destinationRows
            ForEach(result.blockingIssues, id: \.self) { issue in
                Label(issue, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(result.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            ForEach(result.notices, id: \.self) { notice in
                Label(notice, systemImage: "checkmark.circle.dotted")
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
            if result.requiresAcknowledgement {
                Toggle("I understand these copies are not on independent volumes.", isOn: $warningsAcknowledged)
                    .font(.callout.weight(.medium))
            }
            Divider()
            sourceContentsDisclosure
            if hasMediaDetail { mediaDisclosure }
            if hasHistory { historyDisclosure }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
        .onChange(of: result.sourceFingerprint) {
            tree = []
            if showingTree { buildTree() }
        }
    }

    // MARK: - Verdict

    private var hasWarnings: Bool { result.canStart && result.requiresAcknowledgement }

    private var title: LocalizedStringKey {
        if !result.canStart { return "Preflight needs attention" }
        return hasWarnings ? "Preflight has warnings" : "Preflight passed"
    }

    private var symbol: String {
        if !result.canStart { return "exclamationmark.triangle.fill" }
        return hasWarnings ? "exclamationmark.shield.fill" : "checkmark.shield"
    }

    private var color: Color {
        if !result.canStart { return .red }
        return hasWarnings ? .orange : .blue
    }

    private var headline: some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(color)
            if showsSourceName {
                Text("· \(result.source.lastPathComponent)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(result.itemCount) files · \(Format.bytes(result.totalBytes))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var destinationRows: some View {
        ForEach(result.destinations) { destination in
            HStack {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                Text(destination.output.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if let available = destination.availableBytes {
                    Text("\(Format.bytes(available)) free")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Source contents

    private var sourceContentsDisclosure: some View {
        DisclosureGroup(isExpanded: $showingTree) {
            SourceTreeView(nodes: tree)
                .padding(.top, 6)
        } label: {
            disclosureLabel("Source contents", systemImage: "list.bullet.indent", flagged: false)
        }
        .onChange(of: showingTree) {
            if showingTree, tree.isEmpty { buildTree() }
        }
    }

    private func buildTree() {
        tree = SourceTreeNode.build(from: result.items)
    }

    // MARK: - Media analysis

    private var hasMediaDetail: Bool {
        !result.mediaAnalysis.detectedFormats.isEmpty
            || !result.mediaAnalysis.findings.isEmpty
            || !result.mediaAnalysis.clips.isEmpty
            || result.sourceMHLStatus != .absent
    }

    /// Anything inside that an operator would want to know about without
    /// expanding first earns a marker on the disclosure label.
    private var mediaNeedsAttention: Bool {
        if case .untrusted = result.sourceMHLStatus { return true }
        return result.mediaAnalysis.findings.contains { $0.severity != .info }
    }

    private var mediaDisclosure: some View {
        DisclosureGroup(isExpanded: $showingMedia) {
            VStack(alignment: .leading, spacing: 5) {
                if !result.mediaAnalysis.detectedFormats.isEmpty {
                    Label(
                        result.mediaAnalysis.detectedFormats.joined(separator: " · "),
                        systemImage: "camera.metering.multispot"
                    )
                    .font(.callout.weight(.semibold))
                }
                Text("\(result.mediaAnalysis.mediaFileCount) recognized media · \(result.mediaAnalysis.sidecarFileCount) sidecars")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(result.mediaAnalysis.clips.prefix(3)) { clip in
                    let facts = [
                        clip.codec,
                        clip.width.flatMap { width in clip.height.map { "\(width)×\($0)" } },
                        clip.durationSeconds.map { String(format: "%.1fs", $0) },
                        clip.frameRate.map { String(format: "%.2f fps", $0) },
                        clip.audioSampleRate.map { String(format: "%.0f Hz", $0) },
                        clip.cameraModel,
                    ].compactMap { $0 }
                    Text("\(clip.relativePath)\(facts.isEmpty ? "" : " · " + facts.joined(separator: " · "))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(result.mediaAnalysis.findings.prefix(5)) { finding in
                    Label(
                        [finding.relativePath, finding.message].compactMap { $0 }.joined(separator: ": "),
                        systemImage: finding.severity == .error
                            ? "xmark.octagon.fill"
                            : finding.severity == .warning
                                ? "exclamationmark.triangle.fill" : "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        finding.severity == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
                    )
                }
                mhlStatus
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            disclosureLabel(
                "Media analysis",
                systemImage: "camera.metering.multispot",
                flagged: mediaNeedsAttention
            )
        }
    }

    @ViewBuilder
    private var mhlStatus: some View {
        switch result.sourceMHLStatus {
        case .absent:
            EmptyView()
        case .trusted:
            Label(
                "Trusted ASC MHL chain · source digests can be reused",
                systemImage: "link.badge.checkmark"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.green)
        case .untrusted(let reason):
            VStack(alignment: .leading, spacing: 3) {
                Label("ASC MHL found · independent hashing required", systemImage: "link.badge.plus")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Source history

    private var hasHistory: Bool {
        !priorVerifiedTasks.isEmpty || !changedPriorTasks.isEmpty || !similarPriorTasks.isEmpty
    }

    private var historyDisclosure: some View {
        DisclosureGroup(isExpanded: $showingHistory) {
            VStack(alignment: .leading, spacing: 8) {
                if !priorVerifiedTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("This exact source plan was verified before", systemImage: "clock.arrow.circlepath")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.blue)
                        ForEach(priorVerifiedTasks.prefix(3)) { task in
                            Text("\(task.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(task.destinationPaths.joined(separator: " + "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("This is a warning, not a digest-based skip. Preflight will still create a complete new task.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if !changedPriorTasks.isEmpty {
                    historyNotice(
                        title: "This known card has changed since its last verified offload",
                        detail: "Its stable volume identity matches, but the reviewed file plan does not. A complete new transfer will be created.",
                        symbol: "sdcard.badge.exclamationmark",
                        color: .orange,
                        tasks: changedPriorTasks
                    )
                }
                if !similarPriorTasks.isEmpty {
                    historyNotice(
                        title: "A similarly named card was seen before",
                        detail: "The name matches but stable identity and source plan do not. Treat it as different media unless verification proves otherwise.",
                        symbol: "questionmark.folder",
                        color: .secondary,
                        tasks: similarPriorTasks
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            disclosureLabel(
                "Previously seen",
                systemImage: "clock.arrow.circlepath",
                flagged: !changedPriorTasks.isEmpty
            )
        }
    }

    private var priorVerifiedTasks: [TaskHistoryRecord] {
        historyTasks(matching: .unchanged)
    }

    private var changedPriorTasks: [TaskHistoryRecord] {
        historyTasks(matching: .changed)
    }

    private var similarPriorTasks: [TaskHistoryRecord] {
        historyTasks(matching: .similar)
    }

    private func historyTasks(
        matching relationship: SourceHistoryRelationship
    ) -> [TaskHistoryRecord] {
        model.productStore.taskHistory.filter {
            $0.verdict == .verified
                && $0.relationship(
                    toFingerprint: result.sourceFingerprint,
                    volumeIdentifier: result.sourceVolume?.identifier,
                    volumeName: result.sourceVolume?.name
                ) == relationship
        }
    }

    private func historyNotice(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        symbol: String,
        color: Color,
        tasks: [TaskHistoryRecord]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            ForEach(tasks.prefix(2)) { task in
                Text("\(task.createdAt.formatted(date: .abbreviated, time: .omitted)) · \(task.sourcePath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Shared

    private func disclosureLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        flagged: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.medium))
            if flagged {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Needs attention")
            }
        }
    }
}
