import AppKit
import SwiftUI

struct ReportView: View {
    @Bindable var model: TransferViewModel
    let report: TransferReport

    private struct Row: Identifiable {
        let id: String
        let size: Int64
        let digest: String?
        let outcomes: [URL: ItemDestinationOutcome]
    }

    private var rows: [Row] {
        report.items.map {
            Row(id: $0.item.relativePath, size: $0.item.size, digest: $0.sourceDigest, outcomes: $0.outcomes)
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            verdictBanner
            itemsTable
            if model.showLog {
                LogPanel(entries: model.logEntries)
            }
            controls
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Verdict

    /// Quiet green only when every item verified at every destination.
    /// Anything else is loud and specific — never a single collapsed checkmark.
    private var verdictBanner: some View {
        HStack(spacing: 16) {
            Image(systemName: verdict.icon)
                .font(.system(size: 40))
                .foregroundStyle(verdict.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(verdict.title)
                    .font(.title.weight(.bold))
                Text(verdict.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                statLine("\(report.verifiedCount) verified", .green)
                if report.failedCount > 0 { statLine("\(report.failedCount) failed", .red) }
                if report.skippedCount > 0 { statLine("\(report.skippedCount) skipped", .orange) }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(verdict.color.opacity(0.28)), in: .rect(cornerRadius: 16))
    }

    private func statLine(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .monospacedDigit()
    }

    private var verdict: (icon: String, color: Color, title: String, subtitle: String) {
        let destinations = report.destinations.count
        switch report.status {
        case .verified:
            return ("checkmark.seal.fill", .green, "Transfer Verified",
                    "\(report.items.count) files × \(destinations) destination\(destinations == 1 ? "" : "s") — every copy passed checksum verification.")
        case .failed:
            return ("xmark.octagon.fill", .red, "Transfer FAILED",
                    "Some copies did not verify. Do not erase the source media.")
        case .cancelled:
            return ("exclamationmark.triangle.fill", .orange, "Transfer Cancelled",
                    "Stopped before completion — these copies are not complete. Do not erase the source media.")
        }
    }

    // MARK: - Per-file, per-destination results

    private var itemsTable: some View {
        Table(rows) {
            TableColumn("File") { row in
                Text(row.id)
                    .font(.callout)
                    .help(row.id)
            }
            TableColumn("Size") { row in
                Text(Format.bytes(row.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn(report.algorithm.rawValue) { row in
                Text(row.digest ?? "—")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(130)
            TableColumnForEach(report.destinations, id: \.self) { destination in
                TableColumn(destination.lastPathComponent) { (row: Row) in
                    outcomeCell(row.outcomes[destination])
                }
            }
        }
        .frame(minHeight: 220)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func outcomeCell(_ outcome: ItemDestinationOutcome?) -> some View {
        switch outcome {
        case .verified:
            Label("Verified", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let reason):
            Label(reason.slug, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help(reason.detail ?? reason.slug)
        case .skipped(let reason):
            Label("skipped — \(reason.rawValue)", systemImage: "arrow.right.circle")
                .foregroundStyle(.orange)
        case nil:
            Label("no result", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                revealManifest()
            } label: {
                Label("Reveal Manifest", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.glass)
            .disabled(report.manifestLocations.isEmpty)

            Button {
                revealLog()
            } label: {
                Label("Reveal Log", systemImage: "text.document")
            }
            .buttonStyle(.glass)
            .disabled(model.lastLogFileURL == nil)

            Toggle(isOn: $model.showLog) {
                Label("Log", systemImage: "text.alignleft")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)

            Spacer()

            Button {
                model.newTransfer()
            } label: {
                Label("New Transfer", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
        }
    }

    private func revealManifest() {
        guard let location = report.manifestLocations.first else { return }
        let manifest = location.appendingPathComponent(
            ManifestWriter.manifestFileName(shortID: report.shortID))
        NSWorkspace.shared.activateFileViewerSelecting([manifest])
    }

    private func revealLog() {
        guard let url = model.lastLogFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
