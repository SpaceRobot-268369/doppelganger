import SwiftUI

/// The review checkpoint before any destination is touched, presented as a
/// secondary page rather than a modal. It asks for sources, destinations, and
/// how to verify them, draws the resulting plan as a topology, and keeps
/// everything else one disclosure away. Start stays disabled until the
/// displayed plan matches the request exactly.
struct NewOffloadPage: View {
    @Bindable var model: AppModel
    let autoShowLog: Bool
    let onClose: () -> Void

    @State private var preflights: [TransferPreflight] = []
    @State private var scanning = false
    @State private var warningsAcknowledged = false
    @State private var selectedPresetID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                content
                    .frame(maxWidth: 940)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            Divider().opacity(0.45)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: model.draftSource) { invalidatePreflight() }
        .onChange(of: model.draftAdditionalSources) { invalidatePreflight() }
        .onChange(of: model.draftDestinations) { invalidatePreflight() }
        .onChange(of: model.draftName) { invalidatePreflight() }
        .onChange(of: model.draftAlgorithm) { invalidatePreflight() }
        .onChange(of: model.draftDestinationLayout) { invalidatePreflight() }
        .onChange(of: selectedPresetID) { applySelectedPreset() }
        .onAppear { model.refreshDraftFolderName() }
    }

    private var header: some View {
        SecondaryPageHeader(
            backLabel: "Back to Transfers",
            title: "New Offload",
            subtitle: model.draftAttemptKind == .cascade
                ? "Create a separately evidenced onward copy from a verified destination."
                : "Review every output before any destination is touched.",
            onBack: onClose
        )
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 14) {
            OffloadPlanGraph(model: model, preflights: preflights)
            ShootingInfoCard(model: model, selectedPresetID: $selectedPresetID)
            layoutCard
            verificationCard
            contextCard
            if preflights.isEmpty {
                reviewPrompt
            } else {
                ForEach(preflights, id: \.source) { preflight in
                    PreflightResultView(
                        model: model,
                        result: preflight,
                        showsSourceName: preflights.count > 1,
                        warningsAcknowledged: $warningsAcknowledged
                    )
                }
            }
        }
    }

    // MARK: - Output layout

    private var layoutCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Text("Output")
                        .font(.callout.weight(.medium))
                    Picker("Output", selection: $model.draftDestinationLayout) {
                        ForEach(DestinationLayout.allCases) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    Spacer()
                }
                if model.draftDestinationLayout == .newFolder {
                    folderNameRow
                }
                Text(model.draftDestinationLayout.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Every destination, not just the first — each one receives its
                // own complete copy, so each output path is worth reading.
                ForEach(outputPaths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var folderNameRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            if model.draftSources.count > 1 {
                // Each source gets its own folder, so no single name stands for
                // the transfer; the pattern is the honest thing to show.
                Text("One folder per source")
                    .font(.callout.weight(.semibold))
                Text("named YYYYMMDD_REEL")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if model.draftName.isEmpty {
                Text("Add a source or a reel name")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.draftName)
                    .font(.callout.monospaced().weight(.semibold))
                    .textSelection(.enabled)
                Text("named from the reel · YYYYMMDD_REEL")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Where the media lands in every destination. Paths stop at the folder:
    /// naming one file would only ever describe part of the transfer.
    private var outputPaths: [String] {
        model.draftDestinations.map { destination in
            switch model.draftDestinationLayout {
            case .newFolder:
                let folder = model.draftSources.count > 1
                    ? L10n.text("[folder per source]")
                    : model.draftName
                guard !folder.isEmpty else { return destination.path + "/" }
                return destination.appendingPathComponent(folder).path + "/"
            case .directly:
                return destination.path + "/"
            }
        }
    }

    // MARK: - Verification

    private var verificationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    Text("Verification")
                        .font(.callout.weight(.medium))
                    Picker("Verification", selection: $model.draftVerificationProfile) {
                        ForEach(VerificationProfile.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    Spacer()
                    Text("Checksum")
                        .font(.callout.weight(.medium))
                    Menu {
                        ForEach(ChecksumAlgorithm.allCases, id: \.self) { algorithm in
                            Button {
                                model.draftAlgorithm = algorithm
                            } label: {
                                if algorithm == model.draftAlgorithm {
                                    Label(algorithm.displayName, systemImage: "checkmark")
                                } else {
                                    Text(algorithm.displayName)
                                }
                            }
                        }
                    } label: {
                        Text(model.draftAlgorithm.displayName)
                            .font(.callout.monospaced())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("This task's checksum. Settings holds the default for new tasks.")
                }
                HStack(spacing: 8) {
                    Text(model.draftVerificationProfile.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.draftAlgorithmIsCustom {
                        Text("· Checksum overridden for this task")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Project, camera, operator

    private var contextCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 18) {
                    labeledControl("Project") {
                        Picker("Project", selection: $model.selectedProjectID) {
                            Text("No Project").tag(nil as UUID?)
                            ForEach(activeProjects) { project in
                                Text(project.name).tag(project.id as UUID?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }
                    Spacer()
                    labeledControl("Operator") {
                        operatorPicker
                    }
                }
                if let project = model.selectedProject {
                    Divider()
                    projectInfo(project)
                }
            }
        }
    }

    private var operatorPicker: some View {
        Menu {
            ForEach(model.productStore.profiles) { profile in
                Button {
                    model.draftOperatorProfileID = profile.id
                } label: {
                    if profile.id == model.draftOperatorProfile.id {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                OperatorAvatarView(
                    profile: model.draftOperatorProfile,
                    avatarStore: model.productStore.avatars,
                    size: 22
                )
                Text(model.draftOperatorProfile.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .help("Who this task is credited to. Attribution is snapshotted when the transfer starts.")
    }

    private func projectInfo(_ project: ProjectRecord) -> some View {
        let tasks = model.productStore.taskHistory.filter { $0.projectID == project.id }
        let cameras = model.productStore.cameras(for: project.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: project.archivedAt == nil ? "folder.fill" : "archivebox.fill")
                    .foregroundStyle(.tint)
                Text(project.name)
                    .font(.callout.weight(.semibold))
                if !project.productionCompany.isEmpty {
                    Text("· \(project.productionCompany)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let reel = model.draftCamera.map({ model.productStore.suggestedReelName(for: $0) }) {
                    Text("Next reel \(reel)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 7) {
                if !project.shootLocation.isEmpty {
                    infoChip(project.shootLocation, systemImage: "mappin.and.ellipse")
                }
                if let dates = shootDateRange(project) {
                    infoChip(dates, systemImage: "calendar")
                }
                infoChip("\(tasks.count) transfers", systemImage: "arrow.left.arrow.right")
                infoChip("\(cameras.count) cameras", systemImage: "camera")
                if let last = tasks.map(\.updatedAt).max() {
                    infoChip(
                        last.formatted(.relative(presentation: .named)),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }
            if !project.notes.isEmpty {
                Text(project.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func shootDateRange(_ project: ProjectRecord) -> String? {
        let formatter = Date.FormatStyle.dateTime.month(.abbreviated).day()
        switch (project.shootStartDate, project.shootEndDate) {
        case let (start?, end?):
            return "\(start.formatted(formatter)) – \(end.formatted(formatter))"
        case let (start?, nil):
            return start.formatted(formatter)
        case let (nil, end?):
            return end.formatted(formatter)
        default:
            return nil
        }
    }

    private func infoChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    private func labeledControl<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var activeProjects: [ProjectRecord] {
        model.productStore.projects.filter { $0.archivedAt == nil }
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let message = model.draftValidationMessage, preflights.isEmpty {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !model.draftFolderNamesAreUnique {
                Label("Every source needs a unique folder name.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(scanning ? "Scanning…" : preflights.isEmpty ? "Run Preflight" : "Run Again") {
                runPreflight()
            }
            .buttonStyle(.glass)
            .disabled(!model.canStartDraft || scanning || !model.draftFolderNamesAreUnique)
            if !preflights.isEmpty {
                Button {
                    model.startDraftOffloads(
                        autoShowLog: autoShowLog,
                        preflights: preflights,
                        warningsAcknowledged: warningsAcknowledged
                    )
                } label: {
                    Label(startButtonTitle, systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(
                    scanning || preflights.contains(where: { !$0.canStart })
                        || (preflights.contains(where: \.requiresAcknowledgement) && !warningsAcknowledged)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var startButtonTitle: String {
        if preflights.count > 1 { return "Enqueue \(preflights.count) Offloads" }
        return switch model.draftVerificationProfile {
        case .fast: "Start Fast Transfer"
        case .standard, .maximum: "Start Verified Offload"
        }
    }

    // MARK: - Preflight

    private func runPreflight() {
        guard model.canStartDraft, model.draftFolderNamesAreUnique else { return }
        let plans = model.draftSources.map { source in
            (
                source: source,
                folderName: model.draftFolderName(for: source),
                selection: model.draftSelection(for: source)
            )
        }
        let algorithm = model.draftAlgorithm
        let layout = model.draftDestinationLayout
        scanning = true
        warningsAcknowledged = false
        Task {
            let destinations = model.draftDestinations
            let scanned = await withTaskGroup(of: TransferPreflight.self) { group in
                for plan in plans {
                    group.addTask {
                        await TransferPreflight.inspect(
                            source: plan.source,
                            destinationBases: destinations,
                            folderName: plan.folderName,
                            algorithm: algorithm,
                            layout: layout,
                            includedRelativePaths: plan.selection
                        )
                    }
                }
                var results: [TransferPreflight] = []
                for await result in group { results.append(result) }
                return results
            }
            let bySource = Dictionary(uniqueKeysWithValues: scanned.map { ($0.source, $0) })
            let ordered = plans.compactMap { bySource[$0.source] }
            // The draft may have changed while the scan ran; a stale plan must
            // never become a startable one.
            guard ordered.count == plans.count,
                  algorithm == model.draftAlgorithm,
                  layout == model.draftDestinationLayout,
                  zip(ordered, plans).allSatisfy({ result, plan in
                      result.matches(
                          source: plan.source,
                          destinations: model.draftDestinations,
                          folderName: plan.folderName,
                          layout: layout,
                          includedRelativePaths: result.includedRelativePaths
                      )
                          && plan.selection == model.draftSelection(for: plan.source)
                  }) else {
                scanning = false
                return
            }
            preflights = ordered
            scanning = false
        }
    }

    private func invalidatePreflight() {
        preflights = []
        warningsAcknowledged = false
    }

    private func applySelectedPreset() {
        guard let selectedPresetID,
              let preset = model.workflowLibrary.presets.first(where: { $0.id == selectedPresetID })
        else { return }
        model.applyPreset(preset)
        invalidatePreflight()
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
    }
}
