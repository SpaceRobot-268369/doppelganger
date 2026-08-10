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
        if report.status == .failed || report.status == .cancelled {
            NSApp.requestUserAttention(.criticalRequest)
        }
        guard !NSApp.isActive else { return }

        let content = UNMutableNotificationContent()
        let destinations = report.destinations.count
        switch report.status {
        case .paused:
            content.title = L10n.format("%@ paused", sourceName)
            content.body = L10n.text("Stopped at a complete-file boundary. Keep the source connected to resume.")
        case .transferredPendingVerification:
            content.title = L10n.format("%@ transferred", sourceName)
            content.body = L10n.text("Copy complete, but independent destination verification is still required. Keep the source media.")
        case .verified:
            content.title = L10n.format("%@ verified", sourceName)
            content.body = L10n.format(
                "%lld files × %lld destinations — every copy passed checksum verification.",
                Int64(report.items.count), Int64(destinations)
            )
        case .failed:
            content.title = L10n.format("%@ FAILED", sourceName)
            content.body = L10n.format(
                "%lld copies did not verify. Do not erase the source media.",
                Int64(report.failedCount)
            )
            content.sound = .default
        case .cancelled:
            content.title = L10n.format("%@ cancelled", sourceName)
            content.body = L10n.text("Stopped before completion — these copies are not complete. Do not erase the source media.")
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: report.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
