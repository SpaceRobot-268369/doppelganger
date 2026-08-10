import AppKit
import SwiftUI

private enum ProjectCollectionScope: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case archived = "Archived"

    var id: String { rawValue }
}

private enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case details = "Project Info"
    case cameras = "Cameras"
    case transfers = "Transfers"
    case shootingDays = "Shooting Days"
    case media = "Media"
    case evidence = "Evidence"

    var id: String { rawValue }
}

/// Which page of the Projects section is showing. Secondary pages replace the
/// collection in place — no modal windows, no animated transition.
private enum ProjectRoute: Hashable {
    case collection
    case detail(UUID)
    case newProject
}

private enum ProjectStatusFilter: String, CaseIterable, Identifiable {
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
        case .active: [.pending, .paused, .transferredPendingVerification].contains(task.verdict)
        case .verified: task.verdict == .verified
        case .needsAttention: task.verdict == .needsAttention
        case .failed: task.verdict == .failed
        case .cancelled: task.verdict == .cancelled
        }
    }
}

private enum ProjectDateFilter: String, CaseIterable, Identifiable {
    case all = "All Time"
    case today = "Today"
    case sevenDays = "Last 7 Days"
    case thirtyDays = "Last 30 Days"

    var id: String { rawValue }

    func includes(_ date: Date, now: Date = Date()) -> Bool {
        let calendar = Calendar.current
        switch self {
        case .all: return true
        case .today: return calendar.isDate(date, inSameDayAs: now)
        case .sevenDays:
            return date >= calendar.date(byAdding: .day, value: -7, to: now) ?? .distantPast
        case .thirtyDays:
            return date >= calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        }
    }
}

struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var route = ProjectRoute.collection
    @State private var collectionScope = ProjectCollectionScope.all

    var body: some View {
        Group {
            switch route {
            case .collection:
                collection
            case .newProject:
                NewProjectPage(store: model.productStore) { created in
                    goTo(created.map { ProjectRoute.detail($0.id) } ?? .collection)
                }
            case .detail(let id):
                if let project = model.productStore.projects.first(where: { $0.id == id }) {
                    ProjectDetailView(model: model, project: project) { goTo(.collection) }
                } else {
                    collection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Pages swap instantly; a working surface should not animate in.
    private func goTo(_ destination: ProjectRoute) {
        withoutPageAnimation { route = destination }
    }

    private var filteredProjects: [ProjectRecord] {
        model.productStore.projects.filter { project in
            switch collectionScope {
            case .all: true
            case .active: project.archivedAt == nil
            case .archived: project.archivedAt != nil
            }
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 0) {
            collectionHeader
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    scopePicker
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 16)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(filteredProjects) { project in
                            ProjectSummaryCard(
                                project: project,
                                tasks: tasks(for: project),
                                cameras: model.productStore.cameras(for: project.id)
                            ) {
                                goTo(.detail(project.id))
                            }
                        }
                        NewProjectCard { goTo(.newProject) }
                    }
                }
                .padding(24)
            }
        }
    }

    private var collectionHeader: some View {
        collectionTitle
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var collectionTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Projects").font(.largeTitle.weight(.bold))
            Text("Organize offloads by production.").foregroundStyle(.secondary)
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(ProjectCollectionScope.allCases) { scope in
                SubtabFilterChip(
                    "\(scope.rawValue)  \(count(for: scope))",
                    isSelected: collectionScope == scope
                ) { collectionScope = scope }
            }
        }
    }

    private func tasks(for project: ProjectRecord) -> [TaskHistoryRecord] {
        model.productStore.taskHistory.filter { $0.projectID == project.id }
    }

    private func count(for scope: ProjectCollectionScope) -> Int {
        switch scope {
        case .all: model.productStore.projects.count
        case .active: model.productStore.projects.filter { $0.archivedAt == nil }.count
        case .archived: model.productStore.projects.filter { $0.archivedAt != nil }.count
        }
    }

}

private struct ProjectSummaryCard: View {
    let project: ProjectRecord
    let tasks: [TaskHistoryRecord]
    let cameras: [CameraRecord]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Image(systemName: project.archivedAt == nil ? "folder.fill" : "archivebox.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .glassEffect(.regular.tint(.blue.opacity(0.18)), in: .rect(cornerRadius: 13))
                    Spacer()
                    statusBadge
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title3.weight(.semibold)).lineLimit(1)
                    if let activity = tasks.map(\.updatedAt).max() {
                        Text("Last activity \(activity, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No transfer activity yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider().opacity(0.5)
                HStack(spacing: 20) {
                    metric("arrow.left.arrow.right", value: tasks.count, label: "Transfers")
                    metric("calendar", value: shootingDayCount, label: "Shooting Days")
                    metric("camera", value: cameras.count, label: "Cameras")
                }
                HStack(spacing: -5) {
                    ForEach(Array(operators.prefix(4)), id: \.profileID) { person in
                        Circle()
                            .fill(Color.accentColor.opacity(0.23))
                            .frame(width: 25, height: 25)
                            .overlay(Text(initials(person.displayName)).font(.caption2.weight(.bold)))
                            .overlay(Circle().stroke(.background, lineWidth: 2))
                            .help(person.displayName)
                    }
                    if operators.isEmpty {
                        Text("No operators yet").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text("\(operators.count) operator\(operators.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 238, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.separator.opacity(0.45)))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var operators: [OperatorSnapshot] {
        var seen = Set<UUID>()
        return tasks.sorted { $0.updatedAt > $1.updatedAt }.compactMap { task in
            seen.insert(task.operatorSnapshot.profileID).inserted ? task.operatorSnapshot : nil
        }
    }

    private var shootingDayCount: Int {
        Set(tasks.compactMap(\.shootingDay).filter { !$0.isEmpty }).count
    }

    private var needsAttention: Bool {
        tasks.contains { [.needsAttention, .failed].contains($0.verdict) }
    }

    private var statusBadge: some View {
        let title = project.archivedAt != nil ? "Archived" : (needsAttention ? "Attention" : "Active")
        let color: Color = project.archivedAt != nil ? .secondary : (needsAttention ? .orange : .green)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.11), in: Capsule())
    }

    private func metric(_ icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)").font(.callout.weight(.semibold).monospacedDigit())
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

private struct NewProjectCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular.tint(.blue.opacity(0.16)), in: .circle)
                Text("New Project").font(.title3.weight(.semibold))
                Text("Create a production and add its shoot details.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 238)
            .background(.background.secondary.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.separator.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}

/// Creating a production is a working page, not a modal — the same surface the
/// project detail uses, so setting one up and editing it look alike.
private struct NewProjectPage: View {
    @Bindable var store: ProductStore
    /// Hands back the created project so the caller can open it, or `nil` when
    /// the operator backs out.
    let onFinish: (ProjectRecord?) -> Void

    @State private var name = ""
    @State private var description = ""
    @State private var productionCompany = ""
    @State private var shootLocation = ""
    @State private var hasShootDates = false
    @State private var shootStartDate = Date()
    @State private var shootEndDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SecondaryPageHeader(
                backLabel: "Back to Projects",
                title: "New Project",
                subtitle: "Create a production and add its shoot details.",
                onBack: { onFinish(nil) }
            )
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Project") {
                        field("Name") { TextField("Project name", text: $name) }
                        field("Description") {
                            TextField("Production notes and description", text: $description, axis: .vertical)
                                .lineLimit(3...6)
                        }
                    }
                    section("Production") {
                        field("Production Company") {
                            TextField("Company or production unit", text: $productionCompany)
                        }
                        field("Primary Shoot Location") {
                            TextField("Studio, city, or location", text: $shootLocation)
                        }
                    }
                    section("Shoot Dates") {
                        Toggle("Set planned shoot dates", isOn: $hasShootDates)
                        if hasShootDates {
                            HStack(spacing: 20) {
                                DatePicker("Start", selection: $shootStartDate, displayedComponents: .date)
                                DatePicker("End", selection: $shootEndDate, in: shootStartDate..., displayedComponents: .date)
                            }
                        }
                    }
                    Text("Cameras and their reel letters are set up inside the project once it exists.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            Divider().opacity(0.45)
            HStack {
                Spacer()
                Button("Cancel") { onFinish(nil) }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }

    private func create() {
        store.createProject(
            name: name,
            notes: description,
            productionCompany: productionCompany,
            shootLocation: shootLocation,
            shootStartDate: hasShootDates ? shootStartDate : nil,
            shootEndDate: hasShootDates ? max(shootStartDate, shootEndDate) : nil
        )
        let created = store.projects.first {
            $0.name == name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        onFinish(created)
    }

    private func section<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.3)))
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectDetailView: View {
    @Bindable var model: AppModel
    let project: ProjectRecord
    let onBack: () -> Void

    @State private var tab = ProjectDetailTab.overview
    @State private var searchText = ""
    @State private var showingFilters = false
    @State private var status = ProjectStatusFilter.all
    @State private var shootingDay: String?
    @State private var cameraCard: String?
    @State private var source: String?
    @State private var destination: String?
    @State private var date = ProjectDateFilter.all
    @State private var operatorID: UUID?
    @State private var detailTask: TaskHistoryRecord?
    @State private var organizationTask: TaskHistoryRecord?
    @State private var addingCamera = false
    @State private var editingCameraID: UUID?
    @State private var projectName: String
    @State private var projectDescription: String
    @State private var productionCompany: String
    @State private var shootLocation: String
    @State private var hasShootDates: Bool
    @State private var shootStartDate: Date
    @State private var shootEndDate: Date
    @State private var didSaveProject = false

    init(model: AppModel, project: ProjectRecord, onBack: @escaping () -> Void) {
        self.model = model
        self.project = project
        self.onBack = onBack
        _projectName = State(initialValue: project.name)
        _projectDescription = State(initialValue: project.notes)
        _productionCompany = State(initialValue: project.productionCompany)
        _shootLocation = State(initialValue: project.shootLocation)
        _hasShootDates = State(initialValue: project.shootStartDate != nil || project.shootEndDate != nil)
        _shootStartDate = State(initialValue: project.shootStartDate ?? Date())
        _shootEndDate = State(initialValue: project.shootEndDate ?? project.shootStartDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tabs
                    if tab == .transfers {
                        transferTools
                    }
                    tabContent
                }
                .padding(24)
            }
        }
        .sheet(item: $detailTask) { TaskHistoryDetailView(task: $0, store: model.productStore) }
        .sheet(item: $organizationTask) { task in
            TaskOrganizationEditor(task: task, projects: model.productStore.projects) {
                projectID, day, camera, card in
                model.productStore.updateTaskOrganization(
                    taskID: task.id,
                    projectID: projectID,
                    shootingDay: day,
                    cameraLabel: camera,
                    cardLabel: card
                )
            }
        }
    }

    private var projectTasks: [TaskHistoryRecord] {
        model.productStore.taskHistory.filter { $0.projectID == project.id }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var header: some View {
        HStack(spacing: 16) {
            BackButton("Back to Projects", action: onBack)
            Image(systemName: project.archivedAt == nil ? "folder.fill" : "archivebox.fill")
                .font(.system(size: 26)).foregroundStyle(.tint)
            Text(project.name).font(.title.weight(.bold)).lineLimit(1)
            Text(project.archivedAt == nil ? "Active Project" : "Archived")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(project.archivedAt == nil ? Color.green.opacity(0.13) : Color.secondary.opacity(0.12), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ProjectDetailTab.allCases) { value in
                    SubtabFilterChip(tabTitle(value), isSelected: tab == value) { tab = value }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func tabTitle(_ value: ProjectDetailTab) -> String {
        let count: Int? = switch value {
        case .overview, .details: nil
        case .cameras: model.productStore.cameras(for: project.id).count
        case .transfers: projectTasks.count
        case .shootingDays: Set(projectTasks.compactMap(\.shootingDay)).count
        case .media: Set(projectTasks.map(\.sourcePath)).count
        case .evidence: projectTasks.filter { !$0.searchableEvidenceText.isEmpty }.count
        }
        return count.map { "\(value.rawValue)  \($0)" } ?? value.rawValue
    }

    private var transferTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GlassSearchField(
                    prompt: "Search transfers, cards, operators, destinations",
                    text: $searchText
                )
                Button {
                    withAnimation(.snappy) { showingFilters.toggle() }
                } label: {
                    Label("Filters", systemImage: "slider.horizontal.3")
                    if activeFilterCount > 0 { Text("\(activeFilterCount)").monospacedDigit() }
                }
                .buttonStyle(.glass)
            }
            if activeFilterCount > 0 {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(activeFilterLabels, id: \.self) { label in
                            Text(label).font(.caption.weight(.medium))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .glassEffect(.regular, in: .capsule)
                        }
                        Button("Clear All", action: clearFilters)
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                .scrollIndicators(.hidden)
            }
            if showingFilters { filterPanel.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filter transfers").font(.headline)
                Spacer()
                Text("\(activeFilterCount) active").font(.caption).foregroundStyle(.secondary)
                Button("Clear All", action: clearFilters)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(activeFilterCount == 0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], alignment: .leading, spacing: 16) {
                filterGroup("Status") {
                    filterMenu(status.rawValue, values: ProjectStatusFilter.allCases.map { ($0.rawValue, $0) }) { status = $0 }
                }
                filterGroup("Production") {
                    filterMenu("Shooting Day: \(shootingDay ?? "All")", values: optionalValues(shootingDays)) { shootingDay = $0 }
                    filterMenu("Camera/Card: \(cameraCard ?? "All")", values: optionalValues(cameraCards)) { cameraCard = $0 }
                    filterMenu("Source: \(shortPath(source) ?? "All")", values: optionalValues(sources)) { source = $0 }
                    filterMenu("Destination: \(shortPath(destination) ?? "All")", values: optionalValues(destinations)) { destination = $0 }
                }
                filterGroup("Time & People") {
                    filterMenu(date.rawValue, values: ProjectDateFilter.allCases.map { ($0.rawValue, $0) }) { date = $0 }
                    filterMenu("Operator: \(operatorName)", values: operatorValues) { operatorID = $0 }
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .overview: overview
        case .details: projectInfo
        case .cameras: camerasView
        case .transfers: transfers
        case .shootingDays: shootingDaysView
        case .media: mediaView
        case .evidence: evidenceView
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                summaryTile("Transfers", value: projectTasks.count, icon: "arrow.left.arrow.right")
                summaryTile("Verified", value: projectTasks.filter { $0.verdict == .verified }.count, icon: "checkmark.seal")
                summaryTile("Needs Attention", value: projectTasks.filter { [.needsAttention, .failed].contains($0.verdict) }.count, icon: "exclamationmark.triangle")
                summaryTile("Shooting Days", value: shootingDays.count, icon: "calendar")
            }
            if !project.notes.isEmpty {
                quietSection("Notes") { Text(project.notes).foregroundStyle(.secondary) }
            }
            quietSection("Recent Transfers") {
                if projectTasks.isEmpty { Text("No transfers yet.").foregroundStyle(.secondary) }
                ForEach(projectTasks.prefix(5)) { transferRow($0) }
            }
        }
    }

    private var projectInfo: some View {
        VStack(alignment: .leading, spacing: 16) {
            quietSection("Project") {
                VStack(alignment: .leading, spacing: 12) {
                    labeledField("Name") {
                        TextField("Project name", text: $projectName)
                    }
                    labeledField("Description") {
                        TextField("Production notes and description", text: $projectDescription, axis: .vertical)
                            .lineLimit(3...7)
                    }
                }
            }
            quietSection("Production") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], alignment: .leading, spacing: 14) {
                    labeledField("Production Company") {
                        TextField("Company or production unit", text: $productionCompany)
                    }
                    labeledField("Primary Shoot Location") {
                        TextField("Studio, city, or location", text: $shootLocation)
                    }
                }
            }
            quietSection("Shoot Dates") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Set planned shoot dates", isOn: $hasShootDates)
                    if hasShootDates {
                        HStack(spacing: 20) {
                            DatePicker("Start", selection: $shootStartDate, displayedComponents: .date)
                            DatePicker("End", selection: $shootEndDate, in: shootStartDate..., displayedComponents: .date)
                        }
                    }
                }
            }
            HStack {
                if didSaveProject {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                }
                Spacer()
                Button("Save Project", action: saveProject)
                    .buttonStyle(.glassProminent)
                    .tint(.blue)
                    .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Cameras

    private var projectCameras: [CameraRecord] {
        model.productStore.cameras(for: project.id)
    }

    private var camerasView: some View {
        VStack(alignment: .leading, spacing: 16) {
            quietSection("Reel naming") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each camera owns a reel letter. Its tapes are that letter plus a running number — A001, A002 for the A camera, B001 for the B camera.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("New Offload offers this project's cameras and suggests the next reel name; the operator can always override it.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if projectCameras.isEmpty {
                ContentUnavailableView {
                    Label("No cameras yet", systemImage: "camera")
                } description: {
                    Text("Add the cameras this production shoots on so offloads can be labelled by reel.")
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(projectCameras) { camera in
                        if editingCameraID == camera.id {
                            CameraEditor(
                                title: "Edit camera",
                                submitTitle: "Save Camera",
                                takenPrefixes: takenPrefixes(excluding: camera),
                                initial: camera,
                                onSubmit: { draft in
                                    var updated = camera
                                    updated.reelPrefix = draft.reelPrefix
                                    updated.name = draft.name
                                    updated.make = draft.make
                                    updated.model = draft.model
                                    updated.notes = draft.notes
                                    model.productStore.updateCamera(updated)
                                    editingCameraID = nil
                                },
                                onCancel: { editingCameraID = nil }
                            )
                        } else {
                            cameraRow(camera)
                        }
                    }
                }
            }

            if addingCamera {
                CameraEditor(
                    title: "Add a camera",
                    submitTitle: "Add Camera",
                    takenPrefixes: takenPrefixes(excluding: nil),
                    initial: nil,
                    onSubmit: { draft in
                        let created = model.productStore.createCamera(
                            projectID: project.id,
                            reelPrefix: draft.reelPrefix,
                            name: draft.name,
                            make: draft.make,
                            model: draft.model,
                            notes: draft.notes
                        )
                        if created != nil { addingCamera = false }
                    },
                    onCancel: { addingCamera = false }
                )
            } else {
                Button {
                    addingCamera = true
                    editingCameraID = nil
                } label: {
                    Label("Add Camera", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
            }
        }
    }

    private func takenPrefixes(excluding camera: CameraRecord?) -> Set<String> {
        Set(projectCameras.filter { $0.id != camera?.id }.map(\.reelPrefix))
    }

    private func cameraRow(_ camera: CameraRecord) -> some View {
        HStack(spacing: 14) {
            Text(camera.reelPrefix)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(width: 46, height: 46)
                .glassEffect(.regular.tint(.blue.opacity(0.18)), in: .rect(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.displayName).font(.headline)
                Text(camera.hardwareDescription.isEmpty
                     ? String(localized: "Camera model not recorded")
                     : camera.hardwareDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !camera.notes.isEmpty {
                    Text(camera.notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(model.productStore.suggestedReelName(for: camera))
                    .font(.callout.monospaced().weight(.semibold))
                Text("Next reel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                addingCamera = false
                editingCameraID = camera.id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.glass)
            .help("Edit this camera")
            .accessibilityLabel("Edit camera \(camera.displayName)")
            Button { model.productStore.archiveCamera(camera) } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(.glass)
            .help("Retire this camera. Past transfers keep their camera and reel labels.")
            .accessibilityLabel("Retire camera \(camera.displayName)")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.32)))
    }

    private var transfers: some View {
        Group {
            if filteredTasks.isEmpty {
                ContentUnavailableView("No matching transfers", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVStack(spacing: 9) { ForEach(filteredTasks) { transferRow($0) } }
            }
        }
    }

    private var shootingDaysView: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(shootingDays, id: \.self) { day in
                quietSection(day) {
                    ForEach(projectTasks.filter { ($0.shootingDay ?? "Unassigned Day") == day }) { transferRow($0) }
                }
            }
        }
    }

    private var mediaView: some View {
        LazyVStack(spacing: 9) {
            ForEach(Array(Dictionary(grouping: projectTasks, by: \.sourcePath).keys.sorted()), id: \.self) { path in
                let records = projectTasks.filter { $0.sourcePath == path }
                HStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.title3).foregroundStyle(.tint).frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
                        Text(Format.middleTruncated(path, max: 90)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(records.count) transfer\(records.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private var evidenceView: some View {
        let tasks = projectTasks.filter { !$0.searchableEvidenceText.isEmpty }
        return Group {
            if tasks.isEmpty {
                ContentUnavailableView("No indexed evidence", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                LazyVStack(spacing: 9) {
                    ForEach(tasks) { task in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.label).font(.headline)
                                Text("Portable evidence is indexed for this transfer.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Inspect Evidence") { detailTask = task }.buttonStyle(.glass)
                        }
                        .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
                    }
                }
            }
        }
    }

    private func transferRow(_ task: TaskHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: verdictSymbol(task.verdict)).font(.title3)
                .foregroundStyle(verdictColor(task.verdict)).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.label).font(.headline)
                Text([task.cameraLabel, task.cardLabel].compactMap { $0 }.joined(separator: " · ").isEmpty
                     ? URL(fileURLWithPath: task.sourcePath).lastPathComponent
                     : [task.cameraLabel, task.cardLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(task.operatorSnapshot.displayName).font(.callout.weight(.medium))
                Text(task.updatedAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { detailTask = task } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.glass).help("View attempts and evidence")
            Button { organizationTask = task } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.glass).help("Organize transfer")
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.separator.opacity(0.32)))
    }

    private var filteredTasks: [TaskHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return projectTasks.filter { task in
            guard status.includes(task), date.includes(task.createdAt) else { return false }
            if let shootingDay, task.shootingDay != shootingDay { return false }
            if let cameraCard {
                let value = [task.cameraLabel, task.cardLabel].compactMap { $0 }.joined(separator: " · ")
                if value != cameraCard { return false }
            }
            if let source, task.sourcePath != source { return false }
            if let destination, !task.destinationPaths.contains(destination) { return false }
            if let operatorID, task.operatorSnapshot.profileID != operatorID { return false }
            guard !query.isEmpty else { return true }
            return [task.label, task.sourcePath, task.operatorSnapshot.displayName,
                    task.shootingDay ?? "", task.cameraLabel ?? "", task.cardLabel ?? "",
                    task.destinationPaths.joined(separator: " "), task.searchableAttemptText,
                    task.searchableEvidenceText]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var shootingDays: [String] {
        let values = Set(projectTasks.map { $0.shootingDay ?? "Unassigned Day" })
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var cameraCards: [String] { unique(projectTasks.map { [ $0.cameraLabel, $0.cardLabel ].compactMap { $0 }.joined(separator: " · ") }) }
    private var sources: [String] { unique(projectTasks.map(\.sourcePath)) }
    private var destinations: [String] { unique(projectTasks.flatMap(\.destinationPaths)) }
    private var operatorValues: [(String, UUID?)] {
        [("All Operators", nil)] + model.productStore.profiles.map { ($0.displayName, Optional($0.id)) }
    }
    private var operatorName: String {
        guard let operatorID else { return "All" }
        return model.productStore.profiles.first { $0.id == operatorID }?.displayName ?? "All"
    }

    private var activeFilterCount: Int {
        [status != .all, shootingDay != nil, cameraCard != nil, source != nil,
         destination != nil, date != .all, operatorID != nil].filter { $0 }.count
    }
    private var activeFilterLabels: [String] {
        var labels: [String] = []
        if status != .all { labels.append(status.rawValue) }
        if let shootingDay { labels.append("Day: \(shootingDay)") }
        if let cameraCard { labels.append("Camera/Card: \(cameraCard)") }
        if let source { labels.append("Source: \(shortPath(source) ?? source)") }
        if let destination { labels.append("Destination: \(shortPath(destination) ?? destination)") }
        if date != .all { labels.append(date.rawValue) }
        if operatorID != nil { labels.append("Operator: \(operatorName)") }
        return labels
    }

    private func clearFilters() {
        status = .all; shootingDay = nil; cameraCard = nil; source = nil
        destination = nil; date = .all; operatorID = nil
    }
    private func unique(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func optionalValues(_ values: [String]) -> [(String, String?)] {
        [("All", nil)] + values.map { ($0, Optional($0)) }
    }
    private func shortPath(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).lastPathComponent } }

    private func filterMenu<T: Hashable>(_ title: String, values: [(String, T)], onSelect: @escaping (T) -> Void) -> some View {
        Menu {
            ForEach(Array(values.enumerated()), id: \.offset) { _, entry in
                Button(entry.0) { onSelect(entry.1) }
            }
        } label: {
            HStack { Text(title).lineLimit(1); Spacer(); Image(systemName: "chevron.down") }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
    }

    private func filterGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveProject() {
        var updated = project
        updated.name = projectName
        updated.notes = projectDescription
        updated.productionCompany = productionCompany
        updated.shootLocation = shootLocation
        updated.shootStartDate = hasShootDates ? shootStartDate : nil
        updated.shootEndDate = hasShootDates ? max(shootStartDate, shootEndDate) : nil
        model.productStore.updateProject(updated)
        didSaveProject = true
    }

    private func summaryTile(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(15).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func quietSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.3)))
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
        case .paused, .pending: .blue
        case .transferredPendingVerification: .yellow
        case .needsAttention, .failed: .red
        case .cancelled: .secondary
        }
    }
}

/// Inline add/edit form for a project camera. It lives in the page rather than
/// a modal, so setting up a camera never covers the list it belongs to.
private struct CameraEditor: View {
    struct Draft {
        var reelPrefix: String
        var name: String
        var make: String
        var model: String
        var notes: String
    }

    let title: LocalizedStringKey
    let submitTitle: LocalizedStringKey
    let takenPrefixes: Set<String>
    let initial: CameraRecord?
    let onSubmit: (Draft) -> Void
    let onCancel: () -> Void

    @State private var reelPrefix: String
    @State private var name: String
    @State private var make: String
    @State private var model: String
    @State private var notes: String

    init(
        title: LocalizedStringKey,
        submitTitle: LocalizedStringKey,
        takenPrefixes: Set<String>,
        initial: CameraRecord?,
        onSubmit: @escaping (Draft) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.submitTitle = submitTitle
        self.takenPrefixes = takenPrefixes
        self.initial = initial
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _reelPrefix = State(initialValue: initial?.reelPrefix ?? CameraEditor.firstFreePrefix(takenPrefixes))
        _name = State(initialValue: initial?.name ?? "")
        _make = State(initialValue: initial?.make ?? "")
        _model = State(initialValue: initial?.model ?? "")
        _notes = State(initialValue: initial?.notes ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack(alignment: .top, spacing: 14) {
                field("Reel Letter", width: 96) {
                    TextField("A", text: $reelPrefix)
                        .onChange(of: reelPrefix) {
                            reelPrefix = CameraRecord.normalizedPrefix(reelPrefix)
                        }
                }
                field("Camera Name") { TextField("A Camera", text: $name) }
                field("Make") { TextField("ARRI", text: $make) }
                field("Model") { TextField("ALEXA 35", text: $model) }
            }
            field("Notes") { TextField("Lens package, owner, or anything else", text: $notes) }
            HStack(spacing: 10) {
                Label(previewText, systemImage: "tag")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                Button(submitTitle) {
                    onSubmit(Draft(
                        reelPrefix: reelPrefix,
                        name: name,
                        make: make,
                        model: model,
                        notes: notes
                    ))
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.separator.opacity(0.4)))
    }

    private var previewText: String {
        let prefix = CameraRecord.normalizedPrefix(reelPrefix)
        guard !prefix.isEmpty else { return "—" }
        return "\(prefix)001 · \(prefix)002 · \(prefix)003"
    }

    private var problem: LocalizedStringKey? {
        let prefix = CameraRecord.normalizedPrefix(reelPrefix)
        if prefix.isEmpty { return "A camera needs a reel letter, for example A or B." }
        if takenPrefixes.contains(prefix) { return "That reel letter is already used on this project." }
        return nil
    }

    /// Suggests the first unused letter so adding the second camera lands on B.
    private static func firstFreePrefix(_ taken: Set<String>) -> String {
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            let candidate = String(UnicodeScalar(scalar)!)
            if !taken.contains(candidate) { return candidate }
        }
        return ""
    }

    private func field<Content: View>(
        _ title: LocalizedStringKey,
        width: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.4)))
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

struct GlassSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 38)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
