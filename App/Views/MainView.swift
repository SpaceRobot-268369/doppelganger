import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $model.showingNewOffload) {
            NewOffloadSheet(model: model, autoShowLog: autoShowLog)
        }
        .preferredColorScheme(appearance.colorScheme)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .transfers:
            TransfersView(model: model)
        case .sources:
            SourcesView(model: model)
        case .destinations:
            DestinationsView(model: model)
        case .manifests:
            ManifestsView(model: model)
        case .preferences:
            PreferencesView()
        }
    }
}

#Preview {
    MainView(model: AppModel())
}
