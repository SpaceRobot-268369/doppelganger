import AppKit
import SwiftUI

private enum ProjectHistoryScope: Hashable {
    case all
    case noProject
    case project(UUID)
}

private enum HistoryVerdictScope: String, CaseIterable, Identifiable {
    case all = "All Status"
    case active = "Active"
    case verified = "Verified"
    case needsAttention = "Needs Attention"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var id: String { rawValue }

    func includes(_ task: TaskHistoryRecord) -> Bool {
        switch self {
        case .all: true
        case .active:
            [.pending, .paused, .transferredPendingVerification].contains(task.verdict)
        case .verified: task.verdict == .verified
        case .needsAttention: task.verdict == .needsAttention
        case .failed: task.verdict == .failed
        case .cancelled: task.verdict == .cancelled
        }
    }
}

private enum HistoryDateScope: String, CaseIterable, Identifiable {
    case all = "All Time"
    case today = "Today"
    case sevenDays = "7 Days"
    case thirtyDays = "30 Days"

    var id: String { rawValue }

    func includes(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        return switch self {
        case .all: true
        case .today: calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            date >= calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .thirtyDays:
            date >= calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        }
    }
}

private struct HistoryGroup: Identifiable {
    let project: String
    let shootingDay: String
    let cameraAndCard: String
    let tasks: [TaskHistoryRecord]

    var id: String { [project, shootingDay, cameraAndCard].joined(separator: "\u{1F}") }
}

/// Kept while the new project browser settles so the existing organization and
/// evidence surfaces remain available to the replacement implementation.
struct LegacyProjectsView: View {
    @Bindable var model: AppModel
    @State private var newProjectName = ""
    @State private var historyScope = ProjectHistoryScope.all
    @State private var verdictScope = HistoryVerdictScope.all
    @State private var dateScope = HistoryDateScope.all
    @State private var operatorID: UUID?
    @State private var searchText = ""
    @State private var organizationTask: TaskHistoryRecord?
    @State private var historyDetailTask: TaskHistoryRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    workingContext
                    history
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $organizationTask) { task in
            TaskOrganizationEditor(
                task: task,
                projects: model.productStore.projects
            ) { projectID, shootingDay, camera, card in
                model.productStore.updateTaskOrganization(
                    taskID: task.id,
                    projectID: projectID,
                    shootingDay: shootingDay,
                    cameraLabel: camera,
                    cardLabel: card
                )
            }
        }
        .sheet(item: $historyDetailTask) { task in
            TaskHistoryDetailView(task: task, store: model.productStore)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Projects")
                    .font(.largeTitle.weight(.bold))
                Text("Optional working context and searchable transfer history.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("New project", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit(createProject)
            Button("Add", action: createProject)
                .buttonStyle(.glassProminent)
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
    }

    private var workingContext: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working project").font(.headline)
                        Text("New transfer tasks use this project. No Project is always available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(model.selectedProject?.name ?? "No Project")
                        .font(.callout.weight(.semibold))
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        SubtabFilterChip("No Project", isSelected: model.selectedProjectID == nil) {
                            model.selectedProjectID = nil
                        }
                        ForEach(model.productStore.projects) { project in
                            SubtabFilterChip(project.name, isSelected: model.selectedProjectID == project.id) {
                                model.selectedProjectID = project.id
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transfer history")
                        .font(.title2.weight(.bold))
                    Text("Organize catalog entries by Project → Shooting Day → Camera/Card. Evidence is never changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search media, card, operator, destination", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 330)
            }

            filterStrip

            if historyGroups.isEmpty {
                ContentUnavailableView {
                    Label("No matching transfers", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Completed and in-progress catalog tasks will appear here without changing their portable evidence.")
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(historyGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 7) {
                                organizationBadge(group.project, systemImage: "folder")
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                organizationBadge(group.shootingDay, systemImage: "calendar")
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                organizationBadge(group.cameraAndCard, systemImage: "camera")
                                Spacer()
                                Text("\(group.tasks.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(group.tasks) { task in
                                historyRow(task)
                            }
                        }
                    }
                }
            }
        }
    }

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    SubtabFilterChip("All Projects", isSelected: historyScope == .all) {
                        historyScope = .all
                    }
                    SubtabFilterChip("No Project", isSelected: historyScope == .noProject) {
                        historyScope = .noProject
                    }
                    ForEach(model.productStore.projects) { project in
                        SubtabFilterChip(project.name, isSelected: historyScope == .project(project.id)) {
                            historyScope = .project(project.id)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(HistoryVerdictScope.allCases) { scope in
                        SubtabFilterChip(scope.rawValue, isSelected: verdictScope == scope) {
                            verdictScope = scope
                        }
                    }
                    Divider().frame(height: 24)
                    ForEach(HistoryDateScope.allCases) { scope in
                        SubtabFilterChip(scope.rawValue, isSelected: dateScope == scope) {
                            dateScope = scope
                        }
                    }
                    Divider().frame(height: 24)
                    Menu {
                        Button("All Operators") { operatorID = nil }
                        Divider()
                        ForEach(model.productStore.profiles) { profile in
                            Button(profile.displayName) { operatorID = profile.id }
                        }
                    } label: {
                        Label(selectedOperatorName, systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.glass)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var selectedOperatorName: String {
        guard let operatorID else { return L10n.text("All Operators") }
        return model.productStore.profiles.first { $0.id == operatorID }?.displayName
            ?? L10n.text("All Operators")
    }

    private var filteredHistory: [TaskHistoryRecord] {
        model.productStore.taskHistory.filter { task in
            let inProject = switch historyScope {
            case .all: true
            case .noProject: task.projectID == nil
            case .project(let id): task.projectID == id
            }
            guard inProject, verdictScope.includes(task), dateScope.includes(task.createdAt) else { return false }
            if let operatorID, task.operatorSnapshot.profileID != operatorID { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return [
                task.label,
                task.sourcePath,
                task.operatorSnapshot.displayName,
                task.projectName ?? "No Project",
                task.shootingDay ?? "",
                task.cameraLabel ?? "",
                task.cardLabel ?? "",
                task.destinationPaths.joined(separator: " "),
                task.searchableAttemptText,
                task.searchableEvidenceText
            ].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var historyGroups: [HistoryGroup] {
        let grouped = Dictionary(grouping: filteredHistory) { task in
            [
                task.projectName ?? "No Project",
                task.shootingDay ?? "Unassigned Day",
                [task.cameraLabel, task.cardLabel].compactMap { $0 }.joined(separator: " · ")
            ]
        }
        return grouped.map { key, tasks in
            HistoryGroup(
                project: key[0],
                shootingDay: key[1],
                cameraAndCard: key[2].isEmpty ? "Unassigned Camera/Card" : key[2],
                tasks: tasks.sorted { $0.createdAt > $1.createdAt }
            )
        }.sorted {
            if $0.project != $1.project { return $0.project.localizedStandardCompare($1.project) == .orderedAscending }
            if $0.shootingDay != $1.shootingDay { return $0.shootingDay.localizedStandardCompare($1.shootingDay) == .orderedAscending }
            return $0.cameraAndCard.localizedStandardCompare($1.cameraAndCard) == .orderedAscending
        }
    }

    private func organizationBadge(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private func historyRow(_ task: TaskHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: verdictSymbol(task.verdict))
                .font(.title3)
                .foregroundStyle(verdictColor(task.verdict))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.label).font(.headline)
                Text(task.sourcePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(task.destinationPaths.count) destination\(task.destinationPaths.count == 1 ? "" : "s") · \(task.algorithm.displayName) · \(task.verificationProfile.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(task.operatorSnapshot.displayName)
                    .font(.callout.weight(.medium))
                Text(task.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verdictTitle(task.verdict))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(verdictColor(task.verdict))
            }
            Button {
                historyDetailTask = task
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.glass)
            .help("View attempts and evidence")
            Button {
                organizationTask = task
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.glass)
            .help("Organize transfer")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }

    private func verdictTitle(_ verdict: TransferVerdict) -> String {
        let key = switch verdict {
        case .pending: "Pending"
        case .paused: "Paused"
        case .transferredPendingVerification: "Needs Verification"
        case .verified: "Verified"
        case .needsAttention: "Needs Attention"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
        return L10n.text(key)
    }

    private func verdictSymbol(_ verdict: TransferVerdict) -> String {
        switch verdict {
        case .verified: "checkmark.seal.fill"
        case .paused: "pause.circle.fill"
        case .transferredPendingVerification: "clock.badge.exclamationmark.fill"
        case .pending: "clock.fill"
        case .needsAttention, .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle.fill"
        }
    }

    private func verdictColor(_ verdict: TransferVerdict) -> Color {
        switch verdict {
        case .verified: .green
        case .paused: .blue
        case .transferredPendingVerification: .yellow
        case .pending: .blue
        case .needsAttention, .failed: .red
        case .cancelled: .secondary
        }
    }

    private func createProject() {
        model.productStore.createProject(name: newProjectName)
        newProjectName = ""
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.4)))
    }
}

struct TaskHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let task: TaskHistoryRecord
    let attempts: [AttemptHistoryRecord]
    let evidence: [EvidenceArtifactHistoryRecord]
    let audit: [AuditEventRecord]

    init(task: TaskHistoryRecord, store: ProductStore) {
        self.task = task
        attempts = store.attemptHistory(taskID: task.id)
        evidence = store.evidenceArtifacts(taskID: task.id)
        audit = store.auditEvents(taskID: task.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.label).font(.title2.weight(.bold))
                    Text("Immutable attempts, indexed file results, evidence, and audit trail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.glassProminent)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    detailSection("Attempts", count: attempts.count) {
                        if attempts.isEmpty {
                            Text("No attempts have been indexed yet.").foregroundStyle(.secondary)
                        }
                        ForEach(attempts) { attempt in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(attempt.kind.rawValue.capitalized).font(.headline)
                                    Text(verdictLabel(attempt.verdict))
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 3)
                                        .background(.quaternary, in: Capsule())
                                    Spacer()
                                    Text(attempt.operatorSnapshot.displayName).font(.callout)
                                }
                                Text("\(attempt.fileCount) files · \(attempt.algorithm.displayName) · \(attempt.verificationProfile.displayName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let startedAt = attempt.startedAt {
                                    Text(startedAt, format: .dateTime.year().month().day().hour().minute().second())
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                ForEach(attempt.issues, id: \.self) { issue in
                                    Label(issue, systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                            .padding(12)
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11))
                        }
                    }

                    detailSection("Evidence", count: evidence.count) {
                        if evidence.isEmpty {
                            Text("No evidence artifacts have been indexed yet.").foregroundStyle(.secondary)
                        }
                        ForEach(evidence) { artifact in
                            HStack(spacing: 10) {
                                Image(systemName: artifact.status == "written" ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(artifact.status == "written" ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artifact.kind).font(.callout.weight(.semibold))
                                    Text(Format.middleTruncated(artifact.path, max: 92))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
                                } label: { Image(systemName: "folder") }
                                .buttonStyle(.glass)
                                .disabled(!FileManager.default.fileExists(atPath: artifact.path))
                            }
                        }
                    }

                    detailSection("Audit Trail", count: audit.count) {
                        ForEach(audit) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.action.rawValue).font(.callout.weight(.medium))
                                    if let detail = event.detail, !detail.isEmpty {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(event.occurredAt, format: .dateTime.month().day().hour().minute().second())
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 680)
    }

    private func detailSection<Content: View>(
        _ title: LocalizedStringKey,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func verdictLabel(_ verdict: TransferVerdict) -> String {
        let key = switch verdict {
        case .pending: "Pending"
        case .paused: "Paused"
        case .transferredPendingVerification: "Needs Verification"
        case .verified: "Verified"
        case .needsAttention: "Needs Attention"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
        return L10n.text(key)
    }
}

struct TaskOrganizationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let task: TaskHistoryRecord
    let projects: [ProjectRecord]
    let onSave: (UUID?, String?, String?, String?) -> Void

    @State private var projectID: UUID?
    @State private var shootingDay: String
    @State private var cameraLabel: String
    @State private var cardLabel: String

    init(
        task: TaskHistoryRecord,
        projects: [ProjectRecord],
        onSave: @escaping (UUID?, String?, String?, String?) -> Void
    ) {
        self.task = task
        self.projects = projects
        self.onSave = onSave
        _projectID = State(initialValue: task.projectID)
        _shootingDay = State(initialValue: task.shootingDay ?? "")
        _cameraLabel = State(initialValue: task.cameraLabel ?? "")
        _cardLabel = State(initialValue: task.cardLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Organize Transfer")
                    .font(.title2.weight(.bold))
                Text(task.label)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("Project").font(.headline)
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        SubtabFilterChip("No Project", isSelected: projectID == nil) { projectID = nil }
                        ForEach(projects) { project in
                            SubtabFilterChip(project.name, isSelected: projectID == project.id) {
                                projectID = project.id
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Shooting Day")
                    TextField("Day 01 or 2026-08-09", text: $shootingDay)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Camera")
                    TextField("A Camera", text: $cameraLabel)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Card")
                    TextField("C001", text: $cardLabel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("These labels update only the local searchable catalog. Existing manifests, checksums, MHL generations, and destination evidence are not edited.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                Button("Save") {
                    onSave(projectID, optional(shootingDay), optional(cameraLabel), optional(cardLabel))
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
