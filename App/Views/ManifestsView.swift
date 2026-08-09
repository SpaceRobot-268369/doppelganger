import AppKit
import SwiftUI

/// Every manifest the app has ever written to its spool directory — the
/// durable record that outlives sessions and app restarts.
struct ManifestsView: View {
    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case verified = "Verified"
        case attention = "Needs Attention"

        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    @State private var entries: [SpoolManifest] = []
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all

    private var filteredEntries: [SpoolManifest] {
        entries.filter { entry in
            let statusMatches = switch statusFilter {
            case .all: true
            case .verified: entry.status == "verified"
            case .attention: entry.status != "verified"
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let searchMatches = query.isEmpty
                || entry.sourceName.localizedStandardContains(query)
                || entry.id.localizedStandardContains(query)
            return statusMatches && searchMatches
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Manifests")
                    .font(.largeTitle.weight(.bold))
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([TransferSession.spoolDirectory])
                } label: {
                    Label("Spool Folder", systemImage: "folder")
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            filterChips
                .padding(.horizontal, 24)
                .padding(.top, 14)

            if filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(entries.isEmpty
                         ? "Every completed transfer leaves a manifest here."
                         : "No manifests match this search and filter.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            row(entry)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $searchText, prompt: "Source or transfer ID")
        .onAppear(perform: reload)
        .onChange(of: model.completeCount) {
            reload()
        }
    }

    private var filterChips: some View {
        HStack(spacing: 10) {
            statusChip(.all, count: entries.count)
            statusChip(
                .verified,
                count: entries.count { $0.status == "verified" },
                dot: .green
            )
            statusChip(
                .attention,
                count: entries.count { $0.status != "verified" },
                dot: .red
            )
            Spacer()
        }
    }

    private func statusChip(
        _ filter: StatusFilter,
        count: Int,
        dot: Color? = nil
    ) -> some View {
        SubtabFilterChip(
            filter.rawValue,
            count: count,
            dot: dot,
            isSelected: statusFilter == filter
        ) {
            statusFilter = filter
        }
    }

    private func row(_ entry: SpoolManifest) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.statusIcon)
                .font(.title3)
                .foregroundStyle(entry.statusColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.sourceName)
                        .font(.callout.weight(.semibold))
                    Text(entry.statusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.statusColor)
                }
                Text(entry.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.finishedDisplay)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.reportURL])
            } label: {
                Image(systemName: "doc.richtext")
            }
            .buttonStyle(.glass)
            .help("Reveal report in Finder")
            .accessibilityLabel("Reveal report in Finder")
            .disabled(!FileManager.default.fileExists(atPath: entry.reportURL.path))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.manifestURL])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.glass)
            .help("Reveal manifest in Finder")
            .accessibilityLabel("Reveal manifest in Finder")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }

    private func reload() {
        entries = SpoolManifest.loadAll(from: TransferSession.spoolDirectory)
    }
}

/// One manifest found in the spool, decoded just enough for the list row.
struct SpoolManifest: Identifiable {
    let id: String
    let manifestURL: URL
    let reportURL: URL
    let status: String
    let sourceName: String
    let summaryLine: String
    let finishedAt: String

    var statusLabel: String { status.capitalized }

    var statusIcon: String {
        switch status {
        case "verified": "checkmark.seal.fill"
        case "cancelled": "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
    }

    var statusColor: Color {
        switch status {
        case "verified": .green
        case "cancelled": .orange
        default: .red
        }
    }

    var finishedDisplay: String {
        guard let date = try? Date(
            finishedAt,
            strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        ) else { return finishedAt }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func loadAll(from spool: URL) -> [SpoolManifest] {
        let fm = FileManager.default
        guard let transferDirs = try? fm.contentsOfDirectory(
            at: spool, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [SpoolManifest] = []
        for dir in transferDirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                  let manifestURL = files.first(where: {
                      $0.lastPathComponent.hasPrefix("doppelganger-manifest-")
                          && $0.pathExtension == "json"
                  }),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(TransferManifest.self, from: data)
            else { continue }

            let summary = manifest.summary
            entries.append(SpoolManifest(
                id: manifest.transferID,
                manifestURL: manifestURL,
                reportURL: dir.appendingPathComponent(
                    ManifestWriter.reportFileName(
                        shortID: String(manifest.transferID.prefix(8)).lowercased()
                    )
                ),
                status: manifest.status,
                sourceName: URL(fileURLWithPath: manifest.sourceRoot).lastPathComponent,
                summaryLine: "\(summary.itemCount) files · \(Format.bytes(summary.totalBytes))"
                    + " · \(summary.verifiedCount) verified"
                    + (summary.failedCount > 0 ? " · \(summary.failedCount) failed" : "")
                    + " · \(manifest.destinations.count) destination\(manifest.destinations.count == 1 ? "" : "s")",
                finishedAt: manifest.finishedAt
            ))
        }
        // ISO 8601 strings sort chronologically; newest first.
        return entries.sorted { $0.finishedAt > $1.finishedAt }
    }
}
