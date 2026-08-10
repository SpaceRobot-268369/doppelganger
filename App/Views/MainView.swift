import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system
    @AppStorage("onboarding.completed.v1") private var onboardingCompleted = false
    @State private var showingOnboarding = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(model: model) { prepareDemo in
                onboardingCompleted = true
                showingOnboarding = false
                guard prepareDemo else { return }
                do {
                    let workspace = try DemoWorkspaceService.prepare()
                    model.draftDestinations = workspace.destinations
                    Task { @MainActor in
                        await Task.yield()
                        model.beginOffload(source: workspace.source)
                    }
                } catch {
                    model.productStore.reportError(
                        "Demo workspace could not be created: \(error.localizedDescription)"
                    )
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .onAppear {
            if !onboardingCompleted { showingOnboarding = true }
        }
        .alert(
            "Doppelganger Needs Attention",
            isPresented: Binding(
                get: { model.productStore.lastError != nil },
                set: { if !$0 { model.productStore.clearError() } }
            )
        ) {
            Button("OK") { model.productStore.clearError() }
        } message: {
            Text(model.productStore.lastError ?? "An unknown error occurred.")
        }
    }

    /// New Offload is a secondary page over the current section, not a modal:
    /// it is a working surface the operator reviews, not a quick confirmation.
    @ViewBuilder
    private var detail: some View {
        if model.showingNewOffload {
            NewOffloadPage(model: model, autoShowLog: autoShowLog) {
                withoutPageAnimation { model.showingNewOffload = false }
            }
        } else {
            sectionDetail
        }
    }

    @ViewBuilder
    private var sectionDetail: some View {
        switch model.section {
        case .transfers:
            TransfersView(model: model)
        case .compare:
            CompareView()
        case .projects:
            ProjectsView(model: model)
        case .storage:
            ConnectedDisksView(model: model)
        case .manifests:
            ManifestsView(model: model)
        case .help:
            HelpView()
        case .preferences:
            PreferencesView(model: model)
        }
    }
}

#Preview {
    MainView(model: AppModel())
}
