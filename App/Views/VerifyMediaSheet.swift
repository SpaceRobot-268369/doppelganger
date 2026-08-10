import SwiftUI
import UniformTypeIdentifiers

struct VerifyMediaSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var referenceURL: URL?
    @State private var mediaRoot: URL?
    @State private var choosingReference = false
    @State private var choosingMedia = false
    @State private var running = false
    @State private var report: TransferReport?
    @State private var errorMessage: String?

    init(model: AppModel, referenceURL: URL? = nil) {
        self.model = model
        _referenceURL = State(initialValue: referenceURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Verify Existing Media")
                        .font(.title2.weight(.bold))
                    Text("Read-only verification from a Doppelganger JSON manifest or ASC MHL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
            }
            .padding(20)

            Divider()

            VStack(spacing: 14) {
                selectionCard(
                    title: "Reference",
                    symbol: "doc.text.magnifyingglass",
                    url: referenceURL,
                    empty: "Choose or drop an .mhl or Doppelganger manifest"
                ) { choosingReference = true }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, !Self.isDirectory(url) else { return false }
                    referenceURL = url
                    report = nil
                    return true
                }

                selectionCard(
                    title: "Media folder",
                    symbol: "folder.badge.questionmark",
                    url: mediaRoot,
                    empty: "Choose or drop the existing copy to verify"
                ) { choosingMedia = true }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first, Self.isDirectory(url) else { return false }
                    mediaRoot = url
                    report = nil
                    return true
                }

                if let report {
                    resultCard(report)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Verification reports missing, added, size-mismatched, unreadable, and digest-mismatched files. It never writes inside the selected media folder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
            }
            .padding(20)

            Divider()
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                Button {
                    runVerification()
                } label: {
                    Label(running ? "Verifying…" : "Verify Now", systemImage: "checkmark.shield")
                }
                .buttonStyle(.glassProminent)
                .disabled(referenceURL == nil || mediaRoot == nil || running)
            }
            .padding(16)
        }
        .frame(width: 650, height: 560)
        .fileImporter(
            isPresented: $choosingReference,
            allowedContentTypes: [.json, .xml, .data]
        ) { result in
            if case .success(let url) = result { referenceURL = url; report = nil }
        }
        .fileImporter(isPresented: $choosingMedia, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { mediaRoot = url; report = nil }
        }
    }

    private func selectionCard(
        title: String,
        symbol: String,
        url: URL?,
        empty: String,
        choose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(url.map { Format.middleTruncated($0.path) } ?? empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…", action: choose).buttonStyle(.glass)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }

    private func resultCard(_ report: TransferReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: report.status == .verified ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.title)
                .foregroundStyle(report.status == .verified ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
            VStack(alignment: .leading, spacing: 3) {
                Text(report.status == .verified ? "Existing media verified" : "Differences found")
                    .font(.headline)
                Text("\(report.verifiedCount) verified · \(report.failedCount) failed · \(report.issues.count) added-file finding\(report.issues.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            (report.status == .verified ? Color.green : Color.red).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private func runVerification() {
        guard let referenceURL, let mediaRoot else { return }
        running = true
        report = nil
        errorMessage = nil
        Task {
            do {
                report = try await model.verifyExisting(referenceURL: referenceURL, mediaRoot: mediaRoot)
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
