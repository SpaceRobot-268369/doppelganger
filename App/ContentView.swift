import SwiftUI

struct ContentView: View {
    @State private var model = TransferViewModel()

    var body: some View {
        Group {
            switch model.stage {
            case .setup:
                SetupView(model: model)
            case .running:
                RunningView(model: model)
            case .report(let report):
                ReportView(model: model, report: report)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
