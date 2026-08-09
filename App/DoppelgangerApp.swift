import SwiftUI

@main
struct DoppelgangerApp: App {
    var body: some Scene {
        Window("Doppelganger", id: "main") {
            MainView()
                .frame(minWidth: 1000, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
        }
    }
}
