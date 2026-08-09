import AppKit
import SwiftUI

/// Every manifest the app has ever written to its spool directory — the
/// durable record that outlives sessions and app restarts.
struct ManifestsView: View {
    @State private var entries: [SpoolManifest] = []

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

            if entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Every completed transfer leaves a manifest here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: reload)
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
                NSWorkspace.shared.activateFileViewerSelecting([entry.manifestURL])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.glass)
            .help("Reveal manifest in Finder")
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func reload() {
        entries = SpoolManifest.loadAll(from: TransferSession.spoolDirectory)
    }
}

/// One manifest found in the spool, decoded just enough for the list row.
struct SpoolManifest: Identifiable {
    let id: String
    let manifestURL: URL
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
