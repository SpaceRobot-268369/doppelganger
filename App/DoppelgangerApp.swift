import AppKit
import SwiftUI

final class DoppelgangerAppDelegate: NSObject, NSApplicationDelegate {
    var hasRunningTransfers: () -> Bool = { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hasRunningTransfers() else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Transfers are still running"
        alert.informativeText = "Quitting interrupts active copies. Their partial output will be preserved and shown as needing attention next time Doppelganger opens."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct DoppelgangerApp: App {
    @NSApplicationDelegateAdaptor(DoppelgangerAppDelegate.self) private var appDelegate
    /// Owned here, not in MainView, so menu commands can route to it.
    @State private var model = AppModel()

    var body: some Scene {
        Window("Doppelganger", id: "main") {
            MainView(model: model)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear {
                    appDelegate.hasRunningTransfers = { model.runningCount > 0 }
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 700)
        .commands {
            // Reachable from anywhere in the app, whatever page is showing.
            CommandGroup(replacing: .newItem) {
                Button("New Offload") {
                    model.beginOffload()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences…") {
                    model.selectSection(.preferences)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
