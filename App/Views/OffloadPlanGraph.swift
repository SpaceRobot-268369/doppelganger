import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The New Offload plan drawn as what it is: sources on the left, destinations
/// on the right, one connector per pair. Both columns accept Finder drops, and
/// a drop only ever populates the plan — it never scans, queues, or starts.
struct OffloadPlanGraph: View {
    @Bindable var model: AppModel
    let preflights: [TransferPreflight]

    @State private var pickingSource = false
    @State private var pickingDestination = false
    @State private var sourceDropTargeted = false
    @State private var destinationDropTargeted = false
    @State private var sourceDropNotice: DropNotice?
    @State private var destinationDropNotice: DropNotice?
    @State private var hoveredSource: Int?

    private static let tileHeight: CGFloat = 76
    private static let tileSpacing: CGFloat = 10
    private static let connectorWidth: CGFloat = 88

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            columnHeaders
            HStack(alignment: .top, spacing: 0) {
                sourceColumn
                PlanConnectorView(
                    sourceCenters: centers(count: sourceRows.count),
                    destinationCenters: centers(count: model.draftDestinations.count),
                    state: planState,
                    taskCount: model.draftSources.count,
                    highlightedSource: hoveredSource
                )
                .frame(width: Self.connectorWidth, height: connectorHeight)
                // Match the columns' own inset so curves meet tile centres.
                .padding(.top, 6)
                destinationColumn
            }
            if model.draftSources.count > 1 {
                Label(
                    "\(model.draftSources.count) sources are bundled here for review. Each still becomes its own independent task writing to every destination.",
                    systemImage: "square.stack.3d.up"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Label(
                model.draftSources.count > 1 ? "Sources" : "Source",
                systemImage: "sdcard"
            )
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: Self.connectorWidth)
            Label("Destinations", systemImage: "externaldrive.connected.to.line.below")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Geometry

    private func centers(count: Int) -> [CGFloat] {
        (0..<max(count, 0)).map {
            CGFloat($0) * (Self.tileHeight + Self.tileSpacing) + Self.tileHeight / 2
        }
    }

    private func stackHeight(count: Int) -> CGFloat {
        guard count > 0 else { return Self.tileHeight }
        return CGFloat(count) * Self.tileHeight + CGFloat(count - 1) * Self.tileSpacing
    }

    private var connectorHeight: CGFloat {
        max(
            stackHeight(count: sourceRows.count),
            stackHeight(count: model.draftDestinations.count)
        )
    }

    /// The plan reads neutral until preflight has actually inspected it.
    private var planState: PlanConnectorView.PlanState {
        guard !preflights.isEmpty else { return .unreviewed }
        if preflights.contains(where: { !$0.canStart }) { return .blocked }
        if preflights.contains(where: \.requiresAcknowledgement) { return .warning }
        return .ready
    }

    // MARK: - Sources

    /// One row per item the operator actually dropped: a whole folder is one
    /// row, and picked files get a row each. Several files are never crammed
    /// into a single tile — the column shows the plan, item by item.
    private struct SourceRow: Identifiable {
        /// The transfer's source root — the folder the item lives under.
        let source: URL
        /// The single picked item this row stands for, or `nil` for all of it.
        let item: String?

        var id: String { source.standardizedFileURL.path + "\u{0}" + (item ?? "") }
    }

    private var sourceRows: [SourceRow] {
        model.draftSources.flatMap { source -> [SourceRow] in
            guard let selection = model.draftSelection(for: source), !selection.isEmpty else {
                return [SourceRow(source: source, item: nil)]
            }
            return selection
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { SourceRow(source: source, item: $0) }
        }
    }

    private var sourceColumn: some View {
        VStack(spacing: Self.tileSpacing) {
            ForEach(Array(sourceRows.enumerated()), id: \.element.id) { index, row in
                sourceTile(row, index: index)
            }
            if model.draftAttemptKind == .cascade {
                if model.draftSource != nil {
                    Text("A cascade copies from one verified destination; its source is fixed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                dropWell(
                    prompt: "Drop camera cards, folders, or files here",
                    symbol: "sdcard",
                    targeted: sourceDropTargeted,
                    notice: sourceDropNotice
                ) { pickingSource = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(6)
        .background(
            sourceDropTargeted ? Color.accentColor.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 16)
        )
        // The column is mostly empty space and unfilled outlines. Without an
        // explicit shape, a drop onto that space hits nothing at all.
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .fileImporter(
            isPresented: $pickingSource,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { model.addDraftSource(url) }
            }
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: Binding(
                get: { sourceDropTargeted },
                set: { targeted in
                    sourceDropTargeted = targeted
                    if targeted { sourceDropNotice = nil }
                }
            )
        ) { providers in
            accept(providers, asSource: true)
        }
    }

    private func sourceTile(_ row: SourceRow, index: Int) -> some View {
        let source = row.source
        let preflight = preflights.first {
            $0.source.standardizedFileURL == source.standardizedFileURL
        }
        // A picked file names itself and reveals itself; only a whole-folder row
        // ever stands for the folder.
        let target = row.item.map { source.appendingPathComponent($0) } ?? source
        let name = row.item.map { ($0 as NSString).lastPathComponent } ?? source.lastPathComponent
        return HStack(spacing: 10) {
            Image(systemName: row.item == nil
                  ? (Self.isVolumeRoot(source) ? "sdcard.fill" : "folder.fill")
                  : "doc.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 42)
                .glassEffect(.regular, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target.path)
                Text(row.item == nil
                     ? Format.middleTruncated(source.path, max: 44)
                     : L10n.format("in %@", Format.middleTruncated(source.path, max: 40)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(source.path)
                if let detail = Self.sizeDetail(preflight, item: row.item) {
                    Text(detail)
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } label: {
                Image(systemName: "folder")
                    .padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(name) in Finder")
            if model.draftAttemptKind != .cascade {
                Button {
                    if let item = row.item {
                        model.removeDraftSelection(item, from: source)
                    } else {
                        model.removeDraftSource(source)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(row.item == nil
                      ? "Remove this source from the plan"
                      : "Remove this file from the plan")
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.tileHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
        .onHover { hoveredSource = $0 ? index : nil }
    }

    // MARK: - Destinations

    private var destinationColumn: some View {
        VStack(spacing: Self.tileSpacing) {
            ForEach(Array(model.draftDestinations.enumerated()), id: \.offset) { index, destination in
                destinationTile(destination, index: index)
            }
            dropWell(
                prompt: "Drop drives or folders here",
                symbol: "externaldrive",
                targeted: destinationDropTargeted,
                notice: destinationDropNotice
            ) { pickingDestination = true }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(6)
        .background(
            destinationDropTargeted ? Color.accentColor.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: 16)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .fileImporter(
            isPresented: $pickingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { model.addDraftDestination(url) }
            }
        }
        .onDrop(
            of: [.fileURL],
            isTargeted: Binding(
                get: { destinationDropTargeted },
                set: { targeted in
                    destinationDropTargeted = targeted
                    if targeted { destinationDropNotice = nil }
                }
            )
        ) { providers in
            accept(providers, asSource: false)
        }
    }

    private func destinationTile(_ destination: URL, index: Int) -> some View {
        // Every source writes the same folder name into this base, so the exact
        // output path is only unambiguous for a single-source plan.
        let singleSourceOutput: String? = {
            guard model.draftDestinationLayout == .newFolder else { return nil }
            guard model.draftSources.count == 1, let source = model.draftSources.first else { return nil }
            let folder = model.draftFolderName(for: source)
            guard !folder.isEmpty else { return nil }
            return destination.appendingPathComponent(folder).path
        }()
        let free = preflights.first?.destinations.first {
            $0.base.standardizedFileURL == destination.standardizedFileURL
        }?.availableBytes
        return HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 42)
                .glassEffect(.regular, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(destination.lastPathComponent)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let free {
                        Text("· \(Format.bytes(free)) free")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(Format.middleTruncated(destination.path, max: 44))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(destination.path)
                if let singleSourceOutput {
                    Text("→ \(Format.middleTruncated(singleSourceOutput, max: 44))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(singleSourceOutput)
                }
            }
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } label: {
                Image(systemName: "folder")
                    .padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal destination \(destination.lastPathComponent) in Finder")
            Button {
                model.removeDraftDestination(at: index)
            } label: {
                Image(systemName: "xmark")
                    .padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Remove this destination from the plan")
            .accessibilityLabel("Remove destination \(index + 1)")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.tileHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }

    // MARK: - Drop wells

    private func dropWell(
        prompt: LocalizedStringKey,
        symbol: String,
        targeted: Bool,
        notice: DropNotice?,
        choose: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose…", action: choose)
                .buttonStyle(.glass)
                .controlSize(.small)
            if let notice {
                Text(notice.text)
                    .font(.caption2)
                    .foregroundStyle(notice.isProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        // A filled interior, not just an outline: an unfilled shape is not a
        // drop target in the middle, which is exactly where people aim.
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(targeted ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                               : AnyShapeStyle(.quaternary.opacity(0.28)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                    style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [5, 4])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Drop handling

    /// What a drop had to say about itself. A problem explains a refusal; a
    /// note explains something the drop did that the operator did not spell
    /// out, so nothing about the plan is silent.
    struct DropNotice {
        let text: String
        let isProblem: Bool
    }

    /// Finder hands over `public.file-url` items. Resolving them through the
    /// item providers works for folders, files, and mounted volumes alike.
    private func accept(_ providers: [NSItemProvider], asSource: Bool) -> Bool {
        if asSource, model.draftAttemptKind == .cascade {
            sourceDropNotice = DropNotice(
                text: L10n.text("A cascade's source is the verified destination it came from."),
                isProblem: true
            )
            return false
        }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else {
            let notice = DropNotice(
                text: L10n.text("Drop something from Finder — a folder, a card, or files inside one."),
                isProblem: true
            )
            if asSource { sourceDropNotice = notice } else { destinationDropNotice = notice }
            return false
        }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await provider.resolvedFileURL() { urls.append(url) }
            }
            apply(urls, asSource: asSource)
        }
        return true
    }

    /// A dropped folder is transferred whole. Dropped files are transferred as
    /// exactly those files: they are grouped under the folder that holds them,
    /// which becomes the source root only so output paths stay meaningful, and
    /// nothing else under that folder joins the plan.
    @MainActor
    private func apply(_ urls: [URL], asSource: Bool) {
        var wholeFolders: [URL] = []
        // Parent folder → the exact file names picked out of it.
        var selections: [URL: Set<String>] = [:]
        for url in urls {
            if Self.isDirectory(url) {
                wholeFolders.append(url)
            } else {
                let parent = url.deletingLastPathComponent()
                guard Self.isDirectory(parent) else { continue }
                selections[parent.standardizedFileURL, default: []].insert(url.lastPathComponent)
            }
        }

        guard !wholeFolders.isEmpty || !selections.isEmpty else {
            let notice = DropNotice(
                text: L10n.text("Those items could not be read. Nothing in the plan changed."),
                isProblem: true
            )
            if asSource { sourceDropNotice = notice } else { destinationDropNotice = notice }
            return
        }

        guard asSource else {
            // A destination is always a folder; dropped files name the folder
            // they live in, and nothing about the plan's contents changes.
            var seen = Set<String>()
            let folders = (wholeFolders + selections.keys)
                .filter { seen.insert($0.standardizedFileURL.path).inserted }
            for folder in folders { model.addDraftDestination(folder) }
            destinationDropNotice = selections.isEmpty ? nil : DropNotice(
                text: L10n.text("A destination is a folder, so the folder holding those files was added."),
                isProblem: false
            )
            return
        }

        for folder in wholeFolders { model.addDraftSource(folder) }
        for (parent, names) in selections {
            model.addDraftSource(parent, selecting: names)
        }

        let selectedCount = selections.values.reduce(0) { $0 + $1.count }
        sourceDropNotice = selectedCount == 0 ? nil : DropNotice(
            text: L10n.format(
                "Transferring only the %lld selected file(s). Nothing else in that folder is included.",
                Int64(selectedCount)
            ),
            isProblem: false
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.standardizedFileURL.path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// What the scan found for one row: the whole folder's count and size, or
    /// the picked file's own size. Nothing is shown before preflight has run —
    /// the page never states a figure it has not measured.
    private static func sizeDetail(_ preflight: TransferPreflight?, item: String?) -> String? {
        guard let preflight else { return nil }
        guard let item else {
            return "\(preflight.itemCount) files · \(Format.bytes(preflight.totalBytes))"
        }
        guard let match = preflight.items.first(where: { $0.relativePath == item }) else {
            return nil
        }
        return Format.bytes(match.size)
    }

    /// Cheap check so a mounted card gets the card icon without touching disk
    /// metadata on every render pass.
    private static func isVolumeRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/" || url.deletingLastPathComponent().path == "/Volumes"
    }
}

extension NSItemProvider {
    /// Finder's drag payload as a file URL. `loadObject` handles both the
    /// in-place file URLs Finder provides and bookmark-backed items.
    ///
    /// `nonisolated(nonsending)` runs it on the caller's actor, so the
    /// main-actor drop handler never has to send this non-Sendable provider.
    nonisolated(nonsending) func resolvedFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
