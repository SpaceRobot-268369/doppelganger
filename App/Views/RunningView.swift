import SwiftUI

struct RunningView: View {
    @Bindable var model: TransferViewModel

    /// Copy reaching 100% must visibly hand off to Verifying — the phase strip
    /// makes the stages impossible to conflate.
    private static let strip: [(phase: TransferPhase, label: String, icon: String)] = [
        (.enumerating, "Enumerate", "list.bullet.rectangle"),
        (.copying, "Copy", "doc.on.doc"),
        (.verifying, "Verify", "checkmark.seal"),
        (.writingManifest, "Manifest", "doc.badge.ellipsis"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            phaseStrip
            progressCluster
            destinationLanes
            if !model.liveFailures.isEmpty {
                failureTicker
            }
            Spacer(minLength: 0)
            if model.showLog {
                LogPanel(entries: model.logEntries)
            }
            controls
        }
        .padding(24)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var currentPhaseIndex: Int {
        Self.strip.firstIndex { $0.phase == model.progress.phase } ?? Self.strip.count
    }

    private var phaseStrip: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(Array(Self.strip.enumerated()), id: \.offset) { index, step in
                    let state: ChipState = index < currentPhaseIndex ? .done
                        : (index == currentPhaseIndex ? .active : .pending)
                    Label(step.label, systemImage: state == .done ? "checkmark" : step.icon)
                        .font(.callout.weight(state == .active ? .semibold : .regular))
                        .foregroundStyle(state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassEffect(
                            state == .active ? .regular.tint(.blue.opacity(0.5)) : .regular,
                            in: .capsule
                        )
                }
            }
        }
        .padding(.top, 6)
    }

    private enum ChipState { case done, active, pending }

    private var progressCluster: some View {
        VStack(spacing: 8) {
            ProgressView(value: model.overallFraction)
                .progressViewStyle(.linear)
                .controlSize(.large)
            HStack {
                Text("\(Int(model.overallFraction * 100))% — \(model.planItemCount) files, \(Format.bytes(model.planTotalBytes))")
                Spacer()
                if model.throughputBytesPerSecond > 0 {
                    Text(Format.rate(model.throughputBytesPerSecond))
                }
                if let eta = model.etaSeconds {
                    Text("about \(Format.eta(eta)) left")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()
            if let current = model.progress.currentRelativePath {
                Text(Format.middleTruncated(current, max: 70))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var destinationLanes: some View {
        VStack(spacing: 8) {
            ForEach(model.destinations, id: \.self) { destination in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.tint)
                    Text(destination.lastPathComponent)
                        .font(.callout)
                        .frame(width: 140, alignment: .leading)
                    ProgressView(value: laneFraction(for: destination))
                        .progressViewStyle(.linear)
                    Text(laneCaption(for: destination))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func laneFraction(for destination: URL) -> Double {
        switch model.progress.phase {
        case .enumerating:
            return 0
        case .copying:
            guard model.planTotalBytes > 0 else { return 0 }
            return min(Double(model.progress.copiedBytes) / Double(model.planTotalBytes), 1)
        default:
            return model.verifyFraction(for: destination)
        }
    }

    private func laneCaption(for destination: URL) -> String {
        switch model.progress.phase {
        case .enumerating: ""
        case .copying: "copying"
        default: "verifying \(Int(model.verifyFraction(for: destination) * 100))%"
        }
    }

    private var failureTicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("\(model.liveFailures.count) failure(s) so far", systemImage: "exclamationmark.octagon.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            ForEach(Array(model.liveFailures.suffix(3).enumerated()), id: \.offset) { _, failure in
                Text("\(failure.relativePath) → \(failure.destination.lastPathComponent): \(failure.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular.tint(.red.opacity(0.25)), in: .rect(cornerRadius: 12))
    }

    private var controls: some View {
        HStack {
            Toggle(isOn: $model.showLog) {
                Label("Log", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)
            Spacer()
            Button(role: .cancel) {
                model.cancel()
            } label: {
                Label(model.cancelRequested ? "Cancelling…" : "Cancel", systemImage: "stop.fill")
            }
            .buttonStyle(.glass)
            .tint(.red)
            .disabled(model.cancelRequested)
        }
    }
}
