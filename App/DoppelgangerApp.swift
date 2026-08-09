import SwiftUI

@main
struct DoppelgangerApp: App {
    var body: some Scene {
        Window("Doppelganger", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
