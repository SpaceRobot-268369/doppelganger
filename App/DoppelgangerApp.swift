import AppKit
import SwiftUI

/// What quitting now would cost; counted by `AppModel.quitImpact`.
struct QuitImpact: Equatable, Sendable {
    var running = 0
    var queued = 0
    /// Paused or Fast-pending attempts whose saved record could not bring
    /// them back at the next launch.
    var unrecoverable = 0

    var requiresConfirmation: Bool { running + queued + unrecoverable > 0 }

    var title: String {
        if running > 0 { return L10n.text("Transfers are still running") }
        if queued > 0 { return L10n.text("Transfers are waiting to start") }
        return L10n.text("Some transfers cannot be restored")
    }

    var message: String {
        var paragraphs: [String] = []
        if running > 0 {
            paragraphs.append(L10n.text("Quitting interrupts active copies. Their partial output will be preserved and shown as needing attention next time Doppelganger opens."))
        }
        if queued > 0 {
            paragraphs.append(L10n.text("Queued transfers have not started and will not run."))
        }
        if unrecoverable > 0 {
            paragraphs.append(L10n.text("Some paused or unverified transfers could not be saved for next time and will not reopen as they are now. Keep the source media."))
        }
        return paragraphs.joined(separator: "\n\n")
    }
}

final class DoppelgangerAppDelegate: NSObject, NSApplicationDelegate {
    var quitImpact: () -> QuitImpact = { QuitImpact() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let impact = quitImpact()
        guard impact.requiresConfirmation else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = impact.title
        alert.informativeText = impact.message
        // Work that is running or waiting can keep going; a pause that could
        // not be saved only needs the quit called off.
        alert.addButton(withTitle: impact.running + impact.queued > 0
            ? L10n.text("Keep Running")
            : L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Quit Anyway"))
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
                    appDelegate.quitImpact = { model.quitImpact }
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
