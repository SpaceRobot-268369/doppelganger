import SwiftUI

struct NewOffloadSheet: View {
    @Bindable var model: AppModel
    let autoShowLog: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pickingSource = false
    @State private var pickingDestination = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("New Offload")
                    .font(.title2.weight(.bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            }

            sourceCard
            destinationsCard

            HStack {
                Label("Checksum", systemImage: "number")
                    .font(.callout)
                Spacer()
                Picker("Checksum", selection: $model.draftAlgorithm) {
                    ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                        Text(algorithm.displayName).tag(algorithm)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("xxHash64 is the fast default; MD5 is for MHL workflows and facilities that require it.")
            }
            .padding(.horizontal, 4)

            if let message = model.draftValidationMessage {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.startDraftOffload(autoShowLog: autoShowLog)
            } label: {
                Label("Start Transfer", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .disabled(!model.canStartDraft)
            .keyboardShortcut(.defaultAction)
        }
        .padding(22)
        .frame(width: 520)
    }

    private var sourceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sdcard")
                .font(.title2)
                .foregroundStyle(model.draftSource == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text("Source")
                    .font(.headline)
                Text(model.draftSource.map { Format.middleTruncated($0.path) } ?? "No source selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { pickingSource = true }
                .buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.draftSource = url }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: Self.isDirectory) else { return false }
            model.draftSource = folder
            return true
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private var destinationsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.draftDestinations.enumerated()), id: \.offset) { index, destination in
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Destination \(index + 1)")
                            .font(.headline)
                        Text(Format.middleTruncated(destination.path))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.removeDraftDestination(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this destination")
                }
            }
            if model.draftDestinations.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("Every destination gets a verified copy, a manifest, and a report.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                pickingDestination = true
            } label: {
                Label("Add Destination…", systemImage: "plus")
            }
            .buttonStyle(.glass)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fileImporter(isPresented: $pickingDestination, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.addDraftDestination(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter(Self.isDirectory)
            guard !folders.isEmpty else { return false }
            for folder in folders { model.addDraftDestination(folder) }
            return true
        }
    }
}
