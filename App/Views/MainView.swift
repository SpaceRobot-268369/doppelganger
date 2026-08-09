import SwiftUI

struct MainView: View {
    @State private var model = AppModel()
    @AppStorage("prefs.autoShowLog") private var autoShowLog = false

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 280)
        } detail: {
            detail
        }
        .sheet(isPresented: $model.showingNewOffload) {
            NewOffloadSheet(model: model, autoShowLog: autoShowLog)
        }
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
            ManifestsView()
        }
    }
}

#Preview {
    MainView()
}
