import Foundation
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case transfers
    case sources
    case destinations
    case manifests
    case preferences

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfers: "Transfers"
        case .sources: "Sources"
        case .destinations: "Destinations"
        case .manifests: "Manifests"
        case .preferences: "Preferences"
        }
    }

    var icon: String {
        switch self {
        case .transfers: "arrow.left.arrow.right"
        case .sources: "sdcard"
        case .destinations: "externaldrive"
        case .manifests: "doc.text"
        case .preferences: "gearshape"
        }
    }
}

/// How the app picks its light/dark appearance. `system` follows the Mac.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "prefs.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// `nil` hands the decision back to the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TransferFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case attention
    case verified

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .attention: "Needs Attention"
        case .verified: "Verified"
        }
    }
}

/// Top-level dashboard state: the session list, sidebar routing, the
/// New Offload draft, and recents. Sessions run their own engines; this model
/// only orchestrates them.
@MainActor
@Observable
final class AppModel {
    static let maxConcurrentKey = "prefs.maxConcurrent"
    static let defaultMaxConcurrent = 2

    private(set) var sessions: [TransferSession] = []
    var section: SidebarSection = .transfers
    var filter: TransferFilter = .all
    var showingNewOffload = false

    // New Offload draft, prefilled from the last transfer.
    var draftSource: URL? {
        didSet { persistDraft() }
    }
    var draftDestinations: [URL] = [] {
        didSet { persistDraft() }
    }
    var draftName = ""
    var draftAlgorithm: ChecksumAlgorithm = .xxh64

    private(set) var recentSources: [URL] = []
    private(set) var recentDestinations: [URL] = []

    let volumeWatcher = VolumeWatcher()
    /// A card-like volume just mounted; the Transfers page shows an offload
    /// banner until the user acts or the volume unmounts.
    var mountBanner: MountedVolume?

    private let selectionStore: any SelectionStore
    private let recents: RecentsStore
    private let notifier = TransferNotifier()
    private let dockProgress = DockProgressController()
    private var dockTimer: Timer?

    init(
        selectionStore: any SelectionStore = UserDefaultsSelectionStore(),
        recents: RecentsStore = RecentsStore()
    ) {
        self.selectionStore = selectionStore
        self.recents = recents
        let saved = selectionStore.load()
        draftSource = saved.source
        draftDestinations = saved.destinations
        if let source = saved.source {
            draftName = TransferPreflight.defaultFolderName(for: source)
        }
        recentSources = recents.sources()
        recentDestinations = recents.destinations()
        let journalStore = TransferJournalStore(root: TransferSession.spoolDirectory)
        sessions = journalStore.recoverInterrupted().map(TransferSession.init(interrupted:))
        volumeWatcher.onCardMounted = { [weak self] volume in
            self?.mountBanner = volume
        }
        volumeWatcher.onVolumesChanged = { [weak self] volumes in
            if let banner = self?.mountBanner, !volumes.contains(banner) {
                self?.mountBanner = nil
            }
        }
        // Raising the limit in Settings should release queued transfers
        // without waiting for the next finish event.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleQueued() }
        }
    }

    // MARK: - Session list

    var filteredSessions: [TransferSession] {
        switch filter {
        case .all: sessions
        case .active: sessions.filter(\.isActive)
        case .attention: sessions.filter { $0.report?.status != .verified && !$0.isActive }
        case .verified: sessions.filter { $0.report?.status == .verified }
        }
    }

    var activeCount: Int { sessions.filter(\.isActive).count }
    var completeCount: Int { sessions.count - activeCount }
    var attentionCount: Int {
        sessions.filter { $0.report?.status != .verified && !$0.isActive }.count
    }
    var verifiedCount: Int { sessions.filter { $0.report?.status == .verified }.count }
    var runningCount: Int { sessions.filter(\.isRunning).count }

    var totalPlannedBytes: Int64 { sessions.reduce(0) { $0 + $1.planTotalBytes } }
    var aggregateThroughput: Double { sessions.reduce(0) { $0 + $1.throughputBytesPerSecond } }

    /// Quiet green only while nothing has failed; a failed or cancelled
    /// transfer flips the footer to a loud warning until its card is dismissed.
    var systemNominal: Bool {
        !sessions.contains { $0.hasAttention }
    }

    func remove(_ session: TransferSession) {
        guard !session.isActive else { return }
        sessions.removeAll { $0.id == session.id }
    }

    /// Take a queued session out of line. Running sessions must be cancelled
    /// through the engine instead — their card offers Cancel, not this.
    func withdraw(_ session: TransferSession) {
        guard session.isQueued else { return }
        sessions.removeAll { $0.id == session.id }
    }

    /// A failed/interrupted transfer is retried as a fresh reviewed offload in
    /// a new folder. The old incomplete directory remains untouched.
    func retryAsNewOffload(_ session: TransferSession) {
        draftSource = session.source
        draftDestinations = session.destinationBases
        let stamp = String(Date().formatted(.iso8601).prefix(19))
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "-")
        draftName = TransferPreflight.validFolderName("\(session.label)-retry-\(stamp)")
        draftAlgorithm = session.algorithm
        section = .transfers
        showingNewOffload = true
    }

    // MARK: - Queue scheduling

    /// User-set ceiling on simultaneous transfers; queued sessions start as
    /// slots open. A card reader and its bus rarely reward more than a couple
    /// of concurrent streams.
    private var maxConcurrent: Int {
        let value = UserDefaults.standard.integer(forKey: Self.maxConcurrentKey)
        return value == 0 ? Self.defaultMaxConcurrent : min(max(value, 1), 4)
    }

    private func scheduleQueued() {
        var occupied = Set(sessions.filter(\.isRunning).flatMap(\.resourceIDs))
        while runningCount < maxConcurrent,
              let next = sessions.first(where: {
                  $0.isQueued && $0.resourceIDs.isDisjoint(with: occupied)
              }) {
            next.start()
            occupied.formUnion(next.resourceIDs)
        }
    }

    // MARK: - New Offload

    var draftValidationMessage: String? {
        guard let source = draftSource else { return "Choose a source to offload." }
        guard FileManager.default.fileExists(atPath: source.path) else {
            return "The source folder is not mounted."
        }
        guard !draftDestinations.isEmpty else { return "Add at least one destination." }
        guard !TransferPreflight.validFolderName(draftName).isEmpty else {
            return "Enter a transfer folder name."
        }
        let sourcePath = source.standardizedFileURL.path
        var seen = Set<String>()
        for destination in draftDestinations {
            let path = destination.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                return "Destination \(destination.lastPathComponent) is not mounted."
            }
            guard seen.insert(path).inserted else {
                return "The same destination is listed twice."
            }
            if path == sourcePath || path.hasPrefix(sourcePath + "/") {
                return "A destination is inside the source."
            }
            if sourcePath.hasPrefix(path + "/") {
                return "The source is inside a destination."
            }
        }
        return nil
    }

    var canStartDraft: Bool { draftValidationMessage == nil }

    func addDraftDestination(_ url: URL) {
        draftDestinations.append(url)
    }

    func removeDraftDestination(at index: Int) {
        guard draftDestinations.indices.contains(index) else { return }
        draftDestinations.remove(at: index)
    }

    /// Open the New Offload sheet, optionally pre-selecting a source (used by
    /// the Sources page's quick-offload action).
    func beginOffload(source: URL? = nil) {
        if let source {
            draftSource = source
            draftName = TransferPreflight.defaultFolderName(for: source)
        } else if draftName.isEmpty, let draftSource {
            draftName = TransferPreflight.defaultFolderName(for: draftSource)
        }
        section = .transfers
        showingNewOffload = true
    }

    func startDraftOffload(
        autoShowLog: Bool,
        preflight: TransferPreflight,
        warningsAcknowledged: Bool
    ) {
        guard let source = draftSource,
              canStartDraft,
              preflight.canStart,
              preflight.matches(source: source, destinations: draftDestinations, folderName: draftName),
              !preflight.requiresAcknowledgement || warningsAcknowledged
        else { return }
        let session = TransferSession(
            label: preflight.folderName,
            source: source,
            destinations: preflight.requestDestinations,
            algorithm: draftAlgorithm,
            allowSameVolume: warningsAcknowledged
        )
        session.showLog = autoShowLog
        session.onFinished = { [weak self, weak session] in
            guard let self else { return }
            if let session, let report = session.report {
                self.notifier.notify(about: report, sourceName: session.displayName)
            }
            self.scheduleQueued()
            self.refreshDock()
        }
        sessions.append(session)
        recents.noteTransfer(source: source, destinations: draftDestinations)
        recentSources = recents.sources()
        recentDestinations = recents.destinations()
        showingNewOffload = false
        notifier.prepare()
        scheduleQueued()
        refreshDock()
    }

    // MARK: - Dock progress

    /// Aggregate fraction across running transfers, mirrored onto the Dock
    /// icon on a coarse heartbeat — the Dock needs ~seconds, not 10 Hz.
    private func refreshDock() {
        let running = sessions.filter(\.isRunning)
        if running.isEmpty {
            dockTimer?.invalidate()
            dockTimer = nil
            dockProgress.update(fraction: nil, activeCount: activeCount)
            return
        }
        let fraction = running.map(\.overallFraction).reduce(0, +) / Double(running.count)
        dockProgress.update(fraction: fraction, activeCount: activeCount)
        if dockTimer == nil {
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDock() }
            }
        }
    }

    // MARK: - Recents

    func removeRecentSource(_ url: URL) {
        recents.removeSource(url)
        recentSources = recents.sources()
    }

    func removeRecentDestination(_ url: URL) {
        recents.removeDestination(url)
        recentDestinations = recents.destinations()
    }

    private func persistDraft() {
        selectionStore.save(source: draftSource, destinations: draftDestinations)
    }
}
