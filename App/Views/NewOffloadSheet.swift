import SwiftUI

struct NewOffloadSheet: View {
    @Bindable var model: AppModel
    let autoShowLog: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pickingSource = false
    @State private var pickingDestination = false
    @State private var preflight: TransferPreflight?
    @State private var scanning = false
    @State private var warningsAcknowledged = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    folderNameCard
                    sourceCard
                    destinationsCard
                    checksumRow
                    if let preflight { preflightCard(preflight) }
                    else { reviewPrompt }
                }
                .padding(22)
            }
            Divider()
            footer
                .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 620, maxWidth: 620,
               minHeight: 520, idealHeight: 600, maxHeight: 640)
        .onChange(of: model.draftSource) { invalidatePreflight() }
        .onChange(of: model.draftDestinations) { invalidatePreflight() }
        .onChange(of: model.draftName) { invalidatePreflight() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Offload")
                    .font(.title2.weight(.bold))
                Text("Review every output before any destination is touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close New Offload")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var folderNameCard: some View {
        return surface {
            VStack(alignment: .leading, spacing: 8) {
                Label("Transfer folder", systemImage: "folder.badge.plus")
                    .font(.headline)
                TextField("2026-08-09_ALEXA_A001", text: $model.draftName)
                    .textFieldStyle(.roundedBorder)
                Text("A new folder with this name will be created inside every destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceCard: some View {
        surface {
            HStack(spacing: 12) {
                Image(systemName: "sdcard")
                    .font(.title2)
                    .foregroundStyle(model.draftSource == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source").font(.headline)
                    Text(model.draftSource.map { Format.middleTruncated($0.path) } ?? "No source selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { pickingSource = true }
                    .buttonStyle(.glass)
            }
        }
        .fileImporter(isPresented: $pickingSource, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.draftSource = url
                model.draftName = TransferPreflight.defaultFolderName(for: url)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: Self.isDirectory) else { return false }
            model.draftSource = folder
            model.draftName = TransferPreflight.defaultFolderName(for: folder)
            return true
        }
    }

    private var destinationsCard: some View {
        surface {
            VStack(alignment: .leading, spacing: 10) {
                Label("Destinations", systemImage: "externaldrive.connected.to.line.below")
                    .font(.headline)
                ForEach(Array(model.draftDestinations.enumerated()), id: \.offset) { index, destination in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Destination \(index + 1)")
                                .font(.callout.weight(.semibold))
                            Text(Format.middleTruncated(destination.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let folder = TransferPreflight.validFolderName(model.draftName)
                            if !folder.isEmpty {
                                Text("→ \(destination.appendingPathComponent(folder).path)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Button { model.removeDraftDestination(at: index) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this destination")
                        .accessibilityLabel("Remove destination \(index + 1)")
                    }
                }
                if model.draftDestinations.isEmpty {
                    Text("Add one or more independent destination folders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button { pickingDestination = true } label: {
                    Label("Add Destination…", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }
        }
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

    private var checksumRow: some View {
        HStack {
            Label("Checksum", systemImage: "number")
                .font(.callout.weight(.medium))
            Spacer()
            Picker("Checksum", selection: $model.draftAlgorithm) {
                ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.displayName).tag(algorithm)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .help("xxHash64 is the fast default; MD5 is for compatible MHL workflows.")
        }
        .padding(.horizontal, 4)
    }

    private var reviewPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Run preflight to scan the source, check capacity, identify physical volumes, and confirm exact output paths.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(18)
    }

    private func preflightCard(_ result: TransferPreflight) -> some View {
        let hasWarnings = result.canStart && result.requiresAcknowledgement
        let title = !result.canStart
            ? "Preflight needs attention"
            : hasWarnings ? "Preflight has warnings" : "Preflight passed"
        let symbol = !result.canStart
            ? "exclamationmark.triangle.fill"
            : hasWarnings ? "exclamationmark.shield.fill" : "checkmark.shield"
        let color: Color = !result.canStart ? .red : hasWarnings ? .orange : .blue
        return surface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: symbol)
                    .font(.headline)
                    .foregroundStyle(color)
                    Spacer()
                    Text("\(result.itemCount) files · \(Format.bytes(result.totalBytes))")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ForEach(result.destinations) { destination in
                    HStack {
                        Image(systemName: "arrow.turn.down.right")
                            .foregroundStyle(.secondary)
                        Text(destination.output.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        if let available = destination.availableBytes {
                            Text("\(Format.bytes(available)) free")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(result.blockingIssues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if result.requiresAcknowledgement {
                    Toggle("I understand these copies are not on independent volumes.", isOn: $warningsAcknowledged)
                        .font(.callout.weight(.medium))
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let message = model.draftValidationMessage, preflight == nil {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(scanning ? "Scanning…" : preflight == nil ? "Run Preflight" : "Run Again") {
                runPreflight()
            }
            .buttonStyle(.glass)
            .disabled(!model.canStartDraft || scanning)
            if let preflight {
                Button {
                    model.startDraftOffload(
                        autoShowLog: autoShowLog,
                        preflight: preflight,
                        warningsAcknowledged: warningsAcknowledged
                    )
                } label: {
                    Label("Start Verified Offload", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(
                    scanning || !preflight.canStart
                        || (preflight.requiresAcknowledgement && !warningsAcknowledged)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func runPreflight() {
        guard let source = model.draftSource, model.canStartDraft else { return }
        scanning = true
        warningsAcknowledged = false
        Task {
            let result = await TransferPreflight.inspect(
                source: source,
                destinationBases: model.draftDestinations,
                folderName: model.draftName
            )
            guard result.matches(
                source: model.draftSource,
                destinations: model.draftDestinations,
                folderName: model.draftName
            ) else {
                scanning = false
                return
            }
            preflight = result
            scanning = false
        }
    }

    private func invalidatePreflight() {
        preflight = nil
        warningsAcknowledged = false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func surface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }
}
