import AppKit
import Foundation
import UserNotifications

/// Posts a local notification when a transfer reaches a terminal state while
/// the app is in the background. Verdict wording mirrors the cards: quiet
/// success, loud failure, and never "done" for an unverified copy.
@MainActor
final class TransferNotifier {
    private var authorizationRequested = false

    /// Ask once, lazily, when the first transfer starts — not at app launch.
    func prepare() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(about report: TransferReport, sourceName: String) {
        if report.status != .verified {
            NSApp.requestUserAttention(.criticalRequest)
        }
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        let destinations = report.destinations.count
        switch report.status {
        case .verified:
            content.title = "\(sourceName) verified"
            content.body = "\(report.items.count) files × \(destinations) destination\(destinations == 1 ? "" : "s") — every copy passed checksum verification."
        case .failed:
            content.title = "\(sourceName) FAILED"
            content.body = "\(report.failedCount) copies did not verify. Do not erase the source media."
            content.sound = .default
        case .cancelled:
            content.title = "\(sourceName) cancelled"
            content.body = "Stopped before completion — these copies are not complete. Do not erase the source media."
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: report.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
