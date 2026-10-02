import AppKit
import Foundation
import Observation
import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case transfers
    case compare
    case projects
    case storage
    case manifests
    case help
    case preferences

    var id: String { rawValue }

    var title: String {
        let key = switch self {
        case .transfers: "Transfers"
        case .compare: "Compare"
        case .projects: "Projects"
        case .storage: "Storage"
        case .manifests: "Manifests"
        case .help: "Help"
        case .preferences: "Settings"
        }
        return L10n.text(key)
    }

    var icon: String {
        switch self {
        case .transfers: "arrow.left.arrow.right"
        case .compare: "equal.square"
        case .projects: "folder"
        case .storage: "externaldrive.connected.to.line.below"
        case .manifests: "doc.text"
        case .help: "questionmark.circle"
        case .preferences: "gearshape"
        }
    }
}

/// How the app picks its light/dark appearance. `system` follows the Mac.
enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let storageKey = "prefs.appearance"

    var id: String { rawValue }

    var title: String {
        let key = switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
        return L10n.text(key)
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
        let key = switch self {
        case .all: "All"
        case .active: "Active"
        case .attention: "Needs Attention"
        case .verified: "Verified"
        }
        return L10n.text(key)
    }
}

/// The reviewed scope a resumed attempt carries forward.
struct ResumeScope: Equatable, Sendable {
    /// The exact items to transfer, or `nil` for the whole source.
    let includedRelativePaths: Set<String>?
    /// The paused plan's identity; the engine refuses a plan that differs.
    let sourceFingerprint: String
}

/// Why a Resume may not proceed, worded for the operator.
struct ResumeRefusal: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Whether an attempt may still be resumed or repaired from its own card.
enum ContinuationAvailability: Equatable, Sendable {
    /// No linked attempt has taken over any of its destinations.
    case open
    /// Linked resume or repair attempts own these output roots. Continuing the
    /// parent there again would run against files they already published.
    case continued(Set<URL>)
}

/// Which destinations of an attempt a linked resume or repair attempt has
/// taken over. Each destination is continued at most once; the operator
/// carries on from the newest attempt's card.
struct AttemptContinuations: Equatable, Sendable {
    /// parent attempt → linked child attempt → output roots it took over.
    private var claims: [UUID: [UUID: Set<URL>]] = [:]

    /// `.continued` as soon as any child exists, even one that took over no
    /// destination, so a degenerate parent still fails closed.
    func availability(of attemptID: UUID) -> ContinuationAvailability {
        guard let children = claims[attemptID], !children.isEmpty else { return .open }
        return .continued(children.values.reduce(into: Set<URL>()) { $0.formUnion($1) })
    }

    mutating func claim(_ destinations: [URL], of parentID: UUID, by childID: UUID) {
        claims[parentID, default: [:]][childID, default: []].formUnion(destinations)
    }

    /// A linked attempt that wrote nothing (withdrawn before it started, or
    /// stopped before any destination) holds nothing, so what it alone held
    /// is open again.
    mutating func release(child childID: UUID) {
        for parentID in Array(claims.keys) {
            claims[parentID]?.removeValue(forKey: childID)
            if claims[parentID]?.isEmpty == true { claims.removeValue(forKey: parentID) }
        }
    }

    /// A linked attempt finished. One the engine stopped before it reached
    /// any destination (a different card at the same path, a pulled card, a
    /// changed plan) never took its parent's destinations over, so the parent
    /// can be continued again once the cause is fixed. Any other end keeps
    /// the claim.
    mutating func settle(child childID: UUID, with report: TransferReport) {
        if report.neverReachedDestinations { release(child: childID) }
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
    static let checksumAlgorithmKey = "prefs.checksumAlgorithm"
    static let verificationProfileKey = "prefs.verificationProfile"
    static let automaticCameraDetectionKey = "prefs.automaticCameraDetection"
    static let automaticContactSheetKey = "prefs.automaticContactSheet"
    /// Shown, like the interrupted-run issue, on a paused or Fast-pending card
    /// whose saved record does not check out. Issue text stays in the
    /// evidence register (English), as the existing recovered issue does.
    static let unreadableOfferIssue = "The saved record of this paused or unverified transfer could not be read, so it cannot be resumed or verified from here. Treat every output as incomplete and keep the source media."

    private(set) var sessions: [TransferSession] = []
    /// Linked resume/repair attempts already created from each attempt, so a
    /// second click, or a card restored after relaunch, cannot start a
    /// duplicate. Observed by the card's action row.
    private(set) var continuations = AttemptContinuations()
    var section: SidebarSection = .transfers
    var filter: TransferFilter = .all
    /// New Offload is a secondary page over the detail area, not a modal.
    /// Entering and leaving it is instantaneous — see `presentNewOffload()`.
    var showingNewOffload = false

    /// Route to the New Offload page without an animated transition.
    private func presentNewOffload() {
        section = .transfers
        withoutPageAnimation { showingNewOffload = true }
    }

    /// Choose a sidebar section. A secondary page sits over the detail area, so
    /// it has to step aside — otherwise a sidebar click looks broken. The draft
    /// is kept, so returning to New Offload resumes the plan in progress.
    func selectSection(_ newSection: SidebarSection) {
        withoutPageAnimation {
            showingNewOffload = false
            section = newSection
        }
    }

    // New Offload draft, prefilled from the last transfer.
    var draftSource: URL? {
        didSet { persistDraft() }
    }
    /// Additional sources in the current New Offload review. They remain
    /// independent tasks; the array exists only to make batch review fast.
    var draftAdditionalSources: [URL] = []
    /// Exact items to transfer from a source, keyed by standardized source URL.
    /// A source absent from this map transfers in full; a source present here
    /// transfers only what the operator picked, and nothing else under it.
    private(set) var draftSourceSelections: [URL: Set<String>] = [:]
    var draftDestinations: [URL] = [] {
        didSet { persistDraft() }
    }
    /// The transfer folder name. Always `YYYYMMDD_REEL` for a new offload —
    /// derived from the reel, never typed. Cascade and retry set their own,
    /// because they must not land in the folder they came from.
    private(set) var draftName = ""
    /// The date every folder in this draft is stamped with, fixed whenever
    /// the primary's name is derived. A batch's other sources take it too, so
    /// a review that runs past midnight still names every card for one day.
    private(set) var draftFolderDate = Date()
    /// Whether this transfer creates a folder in each destination or writes
    /// straight into it.
    var draftDestinationLayout: DestinationLayout = .newFolder
    var draftAlgorithm: ChecksumAlgorithm = .xxh3 {
        // A checksum chosen for this task must survive unrelated Settings
        // writes, which otherwise re-push the global default onto the draft.
        didSet { if draftAlgorithm != oldValue { draftAlgorithmIsCustom = true } }
    }
    private(set) var draftAlgorithmIsCustom = false
    var draftVerificationProfile: VerificationProfile = .standard
    var selectedProjectID: UUID? {
        // Cameras belong to a project, so changing project drops a stale pick.
        didSet { if selectedProjectID != oldValue { draftCameraID = nil } }
    }
    var draftShootingDay = ""
    var draftCameraLabel = ""
    /// The reel/tape name — "A001". Shown as Reel Name, stored as the catalog's
    /// card label, and the sole input to the transfer folder name.
    var draftCardLabel = "" {
        didSet { if draftCardLabel != oldValue { refreshDraftFolderName() } }
    }
    /// The project camera this offload is attributed to, if any. Choosing one
    /// fills the camera and reel/tape labels; both stay editable afterwards.
    private(set) var draftCameraID: UUID?
    /// Who is credited with this task. `nil` means the active profile.
    var draftOperatorProfileID: UUID?
    private(set) var draftAttemptKind: TransferAttemptKind = .copy
    private(set) var draftParentAttemptID: UUID?

    private(set) var recentSources: [URL] = []
    private(set) var recentDestinations: [URL] = []
    private(set) var destinationBenchmarks: [String: DestinationBenchmarkResult] = [:]
    private(set) var benchmarkingDestinationPaths: Set<String> = []

    let volumeWatcher = VolumeWatcher()
    let productStore: ProductStore
    let workflowLibrary = WorkflowLibraryStore()
    /// A card-like volume just mounted; the Transfers page shows an offload
    /// banner until the user acts or the volume unmounts.
    var mountBanner: MountedVolume?

    private let selectionStore: any SelectionStore
    private let recents: RecentsStore
    private let journalStore: TransferJournalStore
    private let clock: () -> Date
    private let notifier = TransferNotifier()
    private let dockProgress = DockProgressController()
    private var dockTimer: Timer?

    init(
        selectionStore: any SelectionStore = UserDefaultsSelectionStore(),
        recents: RecentsStore = RecentsStore(),
        productStore: ProductStore = ProductStore(),
        // Injectable so tests never run journal recovery against the real
        // spool, which rewrites unfinished journals and clears staging files.
        spoolRoot: URL = TransferSession.spoolDirectory,
        // Folder date stamps read this, so tests can cross midnight.
        clock: @escaping () -> Date = Date.init
    ) {
        self.selectionStore = selectionStore
        self.recents = recents
        self.productStore = productStore
        journalStore = TransferJournalStore(root: spoolRoot)
        self.clock = clock
        draftFolderDate = clock()
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: Self.checksumAlgorithmKey),
           let algorithm = ChecksumAlgorithm(rawValue: value) {
            draftAlgorithm = algorithm
        }
        if let value = defaults.string(forKey: Self.verificationProfileKey),
           let profile = VerificationProfile(rawValue: value) {
            draftVerificationProfile = profile
        }
        let saved = selectionStore.load()
        draftSource = saved.source
        draftDestinations = saved.destinations
        if let source = saved.source {
            draftName = TransferPreflight.defaultFolderName(for: source, at: draftFolderDate)
        }
        recentSources = recents.sources()
        recentDestinations = recents.destinations()
        if let data = defaults.data(forKey: "destinationBenchmarks.v1"),
           let saved = try? JSONDecoder().decode([String: DestinationBenchmarkResult].self, from: data) {
            destinationBenchmarks = saved
        }
        // Unfinished runs come back once, as interrupted. Paused and
        // Fast-pending attempts come back on every launch until resumed or
        // removed, so a quit never takes their Resume (or Verify) with it.
        // A queued run that never started wrote nothing: like the quit alert
        // and the catalog, which closes it as cancelled, it gets no card.
        let interrupted = journalStore.recoverInterrupted()
            .filter { $0.startedAt != nil }
            .map { TransferSession(interrupted: $0) }
        let offered = journalStore.launchOffers().map { offer -> TransferSession in
            switch offer {
            case .restorable(let attempt):
                TransferSession(restoring: attempt)
            case .unreadable(let journal):
                TransferSession(interrupted: journal, issue: Self.unreadableOfferIssue)
            }
        }
        sessions = (interrupted + offered).sorted { $0.createdAt < $1.createdAt }
        // Nothing of this launch has started yet, so any attempt the catalog
        // still holds open was abandoned by an earlier process: close it the
        // way the recovered card reads — failed. A queued task that never
        // started closes as cancelled.
        productStore.closeAbandonedRuns(before: Date())
        // Linked attempts that took their parent's destinations over in an
        // earlier launch still own them, so a restored card cannot offer that
        // parent's Resume or Retry again. One the engine stopped before any
        // destination took nothing over; its parent is offered as it was.
        for journal in journalStore.startedContinuations() {
            guard let parentID = journal.parentAttemptID else { continue }
            continuations.claim(journal.destinations, of: parentID, by: journal.id)
        }
        volumeWatcher.onCardMounted = { [weak self] volume in
            guard UserDefaults.standard.bool(forKey: Self.automaticCameraDetectionKey) else { return }
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
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.draftAlgorithmIsCustom,
                   let value = UserDefaults.standard.string(forKey: Self.checksumAlgorithmKey),
                   let algorithm = ChecksumAlgorithm(rawValue: value) {
                    self.draftAlgorithm = algorithm
                    self.draftAlgorithmIsCustom = false
                }
                if let value = UserDefaults.standard.string(forKey: Self.verificationProfileKey),
                   let profile = VerificationProfile(rawValue: value) {
                    self.draftVerificationProfile = profile
                }
                self.scheduleQueued()
            }
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

    var selectedProject: ProjectRecord? {
        productStore.projects.first { $0.id == selectedProjectID }
    }

    /// Cameras available to the current draft — none until a project is chosen,
    /// because a camera and its reel run belong to a production.
    var draftCameraOptions: [CameraRecord] {
        productStore.cameras(for: selectedProjectID)
    }

    var draftCamera: CameraRecord? {
        draftCameraOptions.first { $0.id == draftCameraID }
    }

    /// The profile credited with this task. Attribution is a snapshot taken at
    /// start; changing the picker later never rewrites a finished transfer.
    var draftOperatorProfile: OperatorProfile {
        productStore.profiles.first { $0.id == draftOperatorProfileID }
            ?? productStore.activeProfile
    }

    /// Choosing a camera fills the catalog labels with the industry
    /// convention — camera name plus its next reel/tape name. Both remain
    /// editable, and clearing the camera leaves what was already typed.
    func selectDraftCamera(_ camera: CameraRecord?) {
        draftCameraID = camera?.id
        guard let camera else { return }
        draftCameraLabel = camera.displayName
        // Setting the reel refreshes the transfer folder: 20260810_A001.
        draftCardLabel = productStore.suggestedReelName(for: camera)
    }

    /// The reel this offload is named after: what the operator entered, or the
    /// convention-shaped default the source implies until they enter one. The
    /// default always reads like a reel — `A001` — never a raw folder name.
    var draftReelName: String {
        let entered = draftCardLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        guard let draftSource else { return "" }
        return TransferPreflight.reelName(for: draftSource)
    }

    /// Transfer folders always read `YYYYMMDD_REEL`. Cascade and retry keep the
    /// distinct names they were given, since they must not collide with the
    /// folder they were derived from.
    func refreshDraftFolderName() {
        guard draftAttemptKind == .copy else { return }
        let reel = draftReelName
        // The one date every folder in this draft is named for.
        draftFolderDate = clock()
        draftName = reel.isEmpty ? "" : TransferPreflight.defaultFolderName(reel: reel, at: draftFolderDate)
    }

    /// Cascade and retry name their own output; everything else is derived.
    private func setExplicitDraftName(_ value: String) {
        draftName = value
    }

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
        // A paused or Fast-pending card would otherwise return at the next
        // launch; removing it is the operator letting it go. A no-op for any
        // other journal.
        journalStore.stopOffering(session.id)
    }

    /// Take a queued session out of line. Running sessions must be cancelled
    /// through the engine instead — their card offers Cancel, not this.
    func withdraw(_ session: TransferSession) {
        guard session.isQueued else { return }
        // A linked attempt that never started wrote nothing; its parent's
        // destinations may be continued again.
        continuations.release(child: session.id)
        sessions.removeAll { $0.id == session.id }
        // The task was cataloged at enqueue; close it now rather than leave a
        // Pending task under Projects > Active that will never run.
        productStore.withdrawQueuedTask(id: session.taskID)
    }

    /// What quitting now would cost. Running work is interrupted and queued
    /// work never starts. A paused or Fast-pending attempt returns at the next
    /// launch, or is carried on by a linked attempt that took it over, so it
    /// counts only when neither holds: ask rather than lose it silently.
    var quitImpact: QuitImpact {
        var impact = QuitImpact()
        var offered: [UUID] = []
        for session in sessions {
            if session.isRunning {
                impact.running += 1
            } else if session.isQueued {
                impact.queued += 1
            } else if let status = session.report?.status,
                      status == .paused || status == .transferredPendingVerification {
                offered.append(session.id)
            }
        }
        if !offered.isEmpty {
            // The same rules the next launch applies, read once.
            let fates = journalStore.launchFates(of: offered)
            impact.unrecoverable = offered.filter { (fates[$0] ?? .lost) == .lost }.count
        }
        return impact
    }

    /// A failed/interrupted transfer is retried as a fresh reviewed offload in
    /// a new folder. The old incomplete directory remains untouched.
    func retryAsNewOffload(_ session: TransferSession) {
        draftAttemptKind = .copy
        draftParentAttemptID = nil
        draftSource = session.source
        draftAdditionalSources = []
        draftDestinations = session.destinationBases
        let stamp = String(Date().formatted(.iso8601).prefix(19))
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "-")
        setExplicitDraftName(TransferPreflight.validFolderName("\(session.label)-retry-\(stamp)"))
        draftAlgorithm = session.algorithm
        // The new offload reviews exactly what the task was asked to copy.
        // The draft holds only this source now, so stale picks go too.
        draftSourceSelections = [:]
        setDraftSelection(reviewedScope(of: session), for: session.source.standardizedFileURL)
        presentNewOffload()
    }

    /// The items the operator reviewed for this attempt's task, or `nil` for
    /// the whole source. A copy, resume or cascade carries its own. A repair
    /// covers only the pairs that failed at one destination, so it defers to
    /// the attempt it repairs; when that attempt is no longer known, the
    /// whole source is reviewed again rather than the failed subset.
    func reviewedScope(of session: TransferSession) -> Set<String>? {
        guard session.attemptKind == .retry else { return session.includedRelativePaths }
        var visited: Set<UUID> = [session.id]
        var next = session.parentAttemptID
        while let id = next, visited.insert(id).inserted {
            if let parent = sessions.first(where: { $0.id == id }) {
                guard parent.attemptKind == .retry else { return parent.includedRelativePaths }
                next = parent.parentAttemptID
            } else if let parent = journalStore.load(id) {
                guard parent.attemptKind == .retry else { return parent.includedRelativePaths.map { Set($0) } }
                next = parent.parentAttemptID
            } else {
                return nil
            }
        }
        return nil
    }

    /// Create one linked repair attempt per affected destination. Keeping each
    /// retry single-destination makes its scope and terminal verdict exact;
    /// the engine quarantines prior failed bytes and never touches verified
    /// pairs or immutable evidence.
    func retryFailures(_ failedSession: TransferSession) {
        guard let report = failedSession.report,
              report.status == .failed,
              let manifestURL = failedSession.manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ManifestWriter.decode(data)
        else {
            productStore.reportError(L10n.text("The failed attempt's manifest is unavailable; use Retry as New Offload instead."))
            return
        }

        // A destination is repaired at most once from this card: a second
        // repair would run against the copies the first one published.
        let availability = continuation(of: failedSession.id)
        var retries: [TransferSession] = []
        for destination in Self.repairableDestinations(failedSession.destinations, availability: availability) {
            let paths = Self.failedRelativePaths(in: report, at: destination)
            guard !paths.isEmpty else { continue }
            let retry = TransferSession(
                taskID: failedSession.taskID,
                parentAttemptID: failedSession.id,
                attemptKind: .retry,
                label: "\(failedSession.label) · Repair \(failedSession.baseDestination(for: destination).lastPathComponent)",
                source: failedSession.source,
                destinations: [TransferDestination(
                    baseRoot: failedSession.baseDestination(for: destination),
                    outputRoot: destination
                )],
                algorithm: failedSession.algorithm,
                verificationProfile: failedSession.verificationProfile,
                operatorProfile: productStore.activeProfile,
                projectID: failedSession.projectID,
                sourceFingerprint: manifest.sourceFingerprint ?? failedSession.sourceFingerprint,
                allowSameVolume: failedSession.allowSameVolume,
                retryManifest: manifest,
                includedRelativePaths: paths
            )
            retry.showLog = UserDefaults.standard.bool(forKey: "prefs.autoShowLog")
            configureCallbacks(for: retry)
            retries.append(retry)
        }
        guard !retries.isEmpty else {
            productStore.reportError(
                continuationRefusal(availability)
                    ?? L10n.text("This attempt has no failed file/destination pairs to retry.")
            )
            return
        }
        for retry in retries {
            continuations.claim(retry.destinations, of: failedSession.id, by: retry.id)
        }
        if let index = sessions.firstIndex(where: { $0.id == failedSession.id }) {
            sessions.insert(contentsOf: retries, at: index + 1)
        } else {
            sessions.append(contentsOf: retries)
        }
        notifier.prepare()
        scheduleQueued()
        refreshDock()
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
        guard let source = draftSource else { return L10n.text("Choose a source to offload.") }
        let sources = [source] + draftAdditionalSources
        var sourcePaths = Set<String>()
        for candidate in sources {
            guard FileManager.default.fileExists(atPath: candidate.path) else {
                return L10n.format("Source %@ is not mounted.", candidate.lastPathComponent)
            }
            guard sourcePaths.insert(candidate.standardizedFileURL.path).inserted else {
                return L10n.text("The same source is listed twice.")
            }
        }
        guard !draftDestinations.isEmpty else { return L10n.text("Add at least one destination.") }
        guard !TransferPreflight.validFolderName(draftName).isEmpty else {
            return L10n.text("Enter a transfer folder name.")
        }
        var seen = Set<String>()
        for destination in draftDestinations {
            let path = destination.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                return L10n.format("Destination %@ is not mounted.", destination.lastPathComponent)
            }
            guard seen.insert(path).inserted else {
                return L10n.text("The same destination is listed twice.")
            }
            for sourcePath in sourcePaths {
                if path == sourcePath || path.hasPrefix(sourcePath + "/") {
                    return L10n.format(
                        "A destination is inside source %@.",
                        URL(fileURLWithPath: sourcePath).lastPathComponent
                    )
                }
                if sourcePath.hasPrefix(path + "/") {
                    return L10n.format(
                        "Source %@ is inside a destination.",
                        URL(fileURLWithPath: sourcePath).lastPathComponent
                    )
                }
            }
        }
        return nil
    }

    var canStartDraft: Bool { draftValidationMessage == nil }

    func addDraftDestination(_ url: URL) {
        draftDestinations.append(url)
    }

    var draftSources: [URL] {
        (draftSource.map { [$0] } ?? []) + draftAdditionalSources
    }

    /// Add a source to the draft.
    ///
    /// - Parameter selecting: the exact items under `url` to transfer, relative
    ///   to it. `nil` means the whole folder. A selection is what the operator
    ///   literally asked for — dropping three clips transfers three clips, not
    ///   the folder holding them.
    func addDraftSource(_ url: URL, selecting relativePaths: Set<String>? = nil) {
        guard draftAttemptKind != .cascade || draftSource == nil else { return }
        let standardized = url.standardizedFileURL
        if draftSources.contains(where: { $0.standardizedFileURL == standardized }) {
            mergeDraftSelection(relativePaths, into: standardized)
            return
        }
        setDraftSelection(relativePaths, for: standardized)
        if draftSource == nil {
            draftSource = url
            refreshDraftFolderName()
        } else {
            draftAdditionalSources.append(url)
        }
    }

    func removeDraftSource(_ url: URL) {
        draftSourceSelections.removeValue(forKey: url.standardizedFileURL)
        if draftSource?.standardizedFileURL == url.standardizedFileURL {
            let promoted = draftAdditionalSources.first
            if !draftAdditionalSources.isEmpty { draftAdditionalSources.removeFirst() }
            // A promoted source keeps the name it was reviewed under rather
            // than silently reverting to the default.
            draftSource = promoted
            draftCardLabel = ""
            refreshDraftFolderName()
        } else {
            draftAdditionalSources.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        }
    }

    // MARK: - Draft source selections

    /// The exact items to transfer from a source, or `nil` for all of it.
    func draftSelection(for source: URL) -> Set<String>? {
        draftSourceSelections[source.standardizedFileURL]
    }

    /// Drop selected items from a source, transferring everything under it.
    func clearDraftSelection(for source: URL) {
        draftSourceSelections.removeValue(forKey: source.standardizedFileURL)
    }

    /// Drop one picked item from a source. Removing the last one removes the
    /// source itself: an empty selection would otherwise widen the plan back to
    /// the whole folder, which is never what removing a file means.
    func removeDraftSelection(_ item: String, from source: URL) {
        let standardized = source.standardizedFileURL
        guard var selection = draftSourceSelections[standardized] else { return }
        selection.remove(item)
        if selection.isEmpty {
            removeDraftSource(source)
        } else {
            draftSourceSelections[standardized] = selection
        }
    }

    private func setDraftSelection(_ relativePaths: Set<String>?, for standardized: URL) {
        if let relativePaths, !relativePaths.isEmpty {
            draftSourceSelections[standardized] = relativePaths
        } else {
            draftSourceSelections.removeValue(forKey: standardized)
        }
    }

    /// Adding more items to a source the draft already holds widens the
    /// selection. Asking for the whole folder always wins over a subset.
    private func mergeDraftSelection(_ relativePaths: Set<String>?, into standardized: URL) {
        guard let relativePaths, !relativePaths.isEmpty else {
            draftSourceSelections.removeValue(forKey: standardized)
            return
        }
        guard let existing = draftSourceSelections[standardized] else { return }
        draftSourceSelections[standardized] = existing.union(relativePaths)
    }

    // MARK: - Draft folder names

    /// The output folder name for one source. The primary uses the reviewed
    /// reel; every other source uses the reel `draftSourceReels` gives it, so
    /// two cards never default to one folder. Both follow `YYYYMMDD_REEL`,
    /// dated `draftFolderDate`, never the clock at the moment of asking.
    /// A source that is not in the draft has no folder, so nothing matches it.
    func draftFolderName(for source: URL) -> String {
        let standardized = source.standardizedFileURL
        if standardized == draftSource?.standardizedFileURL {
            return TransferPreflight.validFolderName(draftName)
        }
        let reels = draftSourceReels
        guard let index = draftSources.firstIndex(where: { $0.standardizedFileURL == standardized }),
              reels.indices.contains(index)
        else { return "" }
        return TransferPreflight.validFolderName(
            TransferPreflight.defaultFolderName(reel: reels[index], at: draftFolderDate)
        )
    }

    /// Every source in a batch writes into its own folder, so two sources that
    /// resolve to one name must block the review before preflight runs.
    var draftFolderNamesAreUnique: Bool {
        guard draftDestinationLayout == .newFolder else { return true }
        let names = draftSources.map { draftFolderName(for: $0) }
        return !names.contains(where: \.isEmpty) && Set(names).count == names.count
    }

    /// The reel each draft source is named after, in `draftSources` order.
    ///
    /// The primary uses `draftReelName`. Another card that carries a
    /// conventional reel in its own name (`A003`, `CANON_C012_01`) keeps it.
    /// Every other card continues the primary's run — same letters, next tape
    /// number — skipping any reel another source already has. A camera that
    /// suggested `B004` is followed by `B005`, not the A camera's `A002`, and
    /// an unnamed card never defaults onto a reel the batch already uses.
    private var draftSourceReels: [String] {
        guard draftSource != nil else { return [] }
        let primary = draftReelName.uppercased()
        let carried = draftAdditionalSources.map {
            TransferPreflight.conventionalReel(in: $0.lastPathComponent)
        }
        var claimed = Set([primary] + carried.compactMap { $0 })
        // A free-form primary reel has no run to continue; fall back to the
        // A camera from A001, which is what a batch defaulted to before.
        var run = Self.tapeRun(primary) ?? (prefix: "A", number: 1, width: 3)
        var reels = [primary]
        for reel in carried {
            if let reel {
                reels.append(reel)
                continue
            }
            var candidate: String
            repeat {
                run.number += 1
                candidate = Self.tapeName(prefix: run.prefix, number: run.number, width: run.width)
            } while claimed.contains(candidate)
            claimed.insert(candidate)
            reels.append(candidate)
        }
        return reels
    }

    /// A reel read as a running tape: "B004" → ("B", 4, 3). One or two
    /// letters then digits, as `CameraRecord` names them; anything else is a
    /// free-form name with no next tape.
    private static func tapeRun(_ reel: String) -> (prefix: String, number: Int, width: Int)? {
        let prefix = reel.prefix { $0.isASCII && $0.isLetter }
        let digits = reel.dropFirst(prefix.count)
        guard (1...2).contains(prefix.count),
              (1...6).contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits)
        else { return nil }
        return (String(prefix), number, digits.count)
    }

    private static func tapeName(prefix: String, number: Int, width: Int) -> String {
        let digits = String(number)
        return prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// The reel recorded in the catalog for one source's task: the reel its
    /// own folder is named after, never the primary card's reel stamped on the
    /// whole batch. As for a single source, nothing is recorded unless the
    /// operator named the reel; the primary keeps exactly what was entered.
    func draftCatalogReel(for source: URL) -> String {
        guard !draftCardLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let standardized = source.standardizedFileURL
        if standardized == draftSource?.standardizedFileURL { return draftCardLabel }
        let reels = draftSourceReels
        guard let index = draftSources.firstIndex(where: { $0.standardizedFileURL == standardized }),
              reels.indices.contains(index)
        else { return "" }
        return reels[index]
    }

    /// The folder name two sources in the batch would share, so the review can
    /// say which; `nil` when every name is distinct or no folder is created.
    var draftFolderNameCollision: String? {
        guard draftDestinationLayout == .newFolder else { return nil }
        var seen = Set<String>()
        for source in draftSources {
            let name = draftFolderName(for: source)
            if !name.isEmpty, !seen.insert(name).inserted { return name }
        }
        return nil
    }

    /// The relative paths that two or more sources in a reviewed
    /// Directly-in-destination batch would write into one destination, sorted;
    /// empty when none do. A New-folder plan gives its source a folder of its
    /// own, which `draftFolderNamesAreUnique` keeps distinct, so only direct
    /// plans are compared.
    ///
    /// Destinations are grouped by canonical base, so one folder named two
    /// ways is still one destination. Paths are compared as that destination
    /// resolves names: case-folded unless its volume is known to be
    /// case-sensitive, and, as Swift strings, with canonically equivalent
    /// Unicode spellings equal. A shared path is named as the first source in
    /// the batch spells it.
    nonisolated static func directLayoutSharedPaths(in preflights: [TransferPreflight]) -> [String] {
        let direct = preflights.filter { $0.layout == .directly }
        func canonicalBase(_ destination: TransferPreflight.Destination) -> String {
            destination.base.standardizedFileURL.resolvingSymlinksInPath().path
        }
        // Fold case unless every plan saw the base on a case-sensitive volume.
        var foldsCase: [String: Bool] = [:]
        for destination in direct.flatMap(\.destinations) {
            let base = canonicalBase(destination)
            let caseSensitive = destination.volume?.supportsCaseSensitiveNames == true
            foldsCase[base] = (foldsCase[base] ?? false) || !caseSensitive
        }
        let posix = Locale(identifier: "en_US_POSIX")
        // base → landing key → the first source that writes it.
        var claims: [String: [String: (owner: Int, relativePath: String)]] = [:]
        var shared = Set<String>()
        for (owner, preflight) in direct.enumerated() {
            for base in Set(preflight.destinations.map(canonicalBase)) {
                let foldingCase = foldsCase[base] ?? true
                for item in preflight.items {
                    let key = foldingCase
                        ? item.relativePath.folding(options: [.caseInsensitive], locale: posix)
                        : item.relativePath
                    if let claim = claims[base]?[key] {
                        if claim.owner != owner { shared.insert(claim.relativePath) }
                    } else {
                        claims[base, default: [:]][key] = (owner, item.relativePath)
                    }
                }
            }
        }
        return shared.sorted()
    }

    /// Why a reviewed Directly-in-destination batch cannot start, naming up to
    /// three paths its sources share, or `nil` when no two sources share one.
    /// The engine never overwrites, so a shared path would fail one source's
    /// copy mid-offload; the New folder layout gives each source its own.
    nonisolated static func directLayoutCollisionMessage(for preflights: [TransferPreflight]) -> String? {
        let shared = directLayoutSharedPaths(in: preflights)
        guard !shared.isEmpty else { return nil }
        return L10n.format(
            "Sources in this batch would write the same files into one destination: %@. Choose New folder under Output so each source gets its own folder.",
            shared.prefix(3).joined(separator: ", ")
        )
    }

    /// A reviewed plan still writes into the folder the draft names for its
    /// source right now. A Reel Name typed or a camera picked while preflight
    /// scanned fails this. Names are compared the way
    /// `TransferPreflight.matches` compares them.
    func reviewedFolderNameIsCurrent(_ preflight: TransferPreflight) -> Bool {
        let current = draftFolderName(for: preflight.source)
        return !current.isEmpty
            && preflight.folderName == TransferPreflight.validFolderName(current)
    }


    func removeDraftDestination(at index: Int) {
        guard draftDestinations.indices.contains(index) else { return }
        draftDestinations.remove(at: index)
    }

    /// Open the New Offload sheet, optionally pre-selecting a source (used by
    /// the Sources page's quick-offload action).
    func beginOffload(source: URL? = nil) {
        draftAttemptKind = .copy
        draftParentAttemptID = nil
        if let source {
            draftSource = source
            draftAdditionalSources = []
            draftCardLabel = ""
        }
        refreshDraftFolderName()
        // Offloading card after card off the same camera should land on the
        // next reel, not repeat the last one.
        if let camera = draftCamera { selectDraftCamera(camera) }
        presentNewOffload()
    }

    /// Start a normal reviewed New Offload flow with a verified output as its
    /// read-only source. The onward copy is a distinct task, while its first
    /// attempt links back to the verified parent for audit provenance.
    func beginCascade(from session: TransferSession, source destination: URL) {
        guard session.report?.status == .verified,
              session.destinations.contains(destination)
        else { return }
        draftAttemptKind = .cascade
        draftParentAttemptID = session.id
        draftSource = destination
        draftAdditionalSources = []
        draftDestinations = []
        setExplicitDraftName(TransferPreflight.validFolderName(
            "\(TransferPreflight.dateStamp())_CASCADE_\(session.label)"
        ))
        selectedProjectID = session.projectID
        presentNewOffload()
    }

    func applyPreset(_ preset: TransferPresetRecord) {
        draftVerificationProfile = preset.verificationProfile
        if let groupID = preset.destinationGroupID,
           let group = workflowLibrary.groups.first(where: { $0.id == groupID }) {
            draftDestinations = workflowLibrary.destinations(in: group).map {
                URL(fileURLWithPath: $0.path, isDirectory: true)
            }
        }
        // A preset supplies destinations and verification. The transfer
        // folder always follows the YYYYMMDD_REEL convention, so a naming
        // template never renames it.
    
    }

    func startDraftOffload(
        autoShowLog: Bool,
        preflight: TransferPreflight,
        warningsAcknowledged: Bool
    ) {
        startDraftOffloads(
            autoShowLog: autoShowLog,
            preflights: [preflight],
            warningsAcknowledged: warningsAcknowledged
        )
    }

    func startDraftOffloads(
        autoShowLog: Bool,
        preflights: [TransferPreflight],
        warningsAcknowledged: Bool
    ) {
        guard canStartDraft,
              preflights.count == draftSources.count,
              (draftAttemptKind != .cascade || preflights.count == 1),
              Set(preflights.map { $0.source.standardizedFileURL.path })
                == Set(draftSources.map { $0.standardizedFileURL.path }),
              preflights.allSatisfy({ preflight in
                  preflight.canStart
                    && preflight.destinations.map(\.base.standardizedFileURL)
                        == draftDestinations.map(\.standardizedFileURL)
                    && preflight.layout == draftDestinationLayout
                    && (!preflight.requiresAcknowledgement || warningsAcknowledged)
                    // A reviewed selection must still be the current one, or the
                    // transfer would copy something the operator never saw.
                    && selectionIsCurrent(preflight)
              })
        else { return }
        // Two sources writing into one output would race for the same file
        // names. Writing directly into a destination is exempt: there is no
        // per-task folder to be unique, and the engine refuses to overwrite.
        if draftDestinationLayout == .newFolder {
            let outputPaths = preflights.flatMap { $0.destinations.map(\.output.standardizedFileURL.path) }
            guard Set(outputPaths).count == outputPaths.count else {
                productStore.reportError(L10n.text("Every source in a batch needs a unique transfer folder name."))
                return
            }
        }
        // Sources written directly into a destination land side by side. Two
        // cards that both hold DCIM/100/C0001.MP4 would collide there, and the
        // second copy would fail mid-offload: refuse the batch up front.
        if let collision = Self.directLayoutCollisionMessage(for: preflights) {
            productStore.reportError(collision)
            return
        }
        // Each task must still write into the folder the draft names for it.
        // A Reel Name typed or a camera picked while preflight scanned renames
        // it, and the reviewed plan then describes a folder the operator no
        // longer sees: refuse before any session or journal exists.
        if let stale = preflights.first(where: { !reviewedFolderNameIsCurrent($0) }) {
            productStore.reportError(L10n.format(
                "The folder name for %@ changed after preflight. Run preflight again.",
                stale.source.lastPathComponent
            ))
            return
        }

        let attributedProfile = draftOperatorProfile
        for preflight in preflights {
            let session = TransferSession(
                parentAttemptID: draftParentAttemptID,
                attemptKind: draftAttemptKind,
                label: preflight.folderName,
                source: preflight.source,
                destinations: preflight.requestDestinations,
                algorithm: draftAlgorithm,
                verificationProfile: draftVerificationProfile,
                operatorProfile: attributedProfile,
                projectID: selectedProjectID,
                sourceFingerprint: preflight.sourceFingerprint,
                allowSameVolume: warningsAcknowledged,
                // Exactly the reviewed items, so a selection transfers what was
                // asked for and nothing else under the same source.
                includedRelativePaths: preflight.includedRelativePaths,
                duplicateManifests: Dictionary(uniqueKeysWithValues: preflight.destinations.compactMap { destination in
                    destination.duplicateManifest.map { (destination.output.path, $0) }
                })
            )
            productStore.registerTask(
                id: session.id,
                label: preflight.folderName,
                source: preflight.source,
                destinations: preflight.requestDestinations.map(\.outputRoot),
                projectID: selectedProjectID,
                sourceFingerprint: preflight.sourceFingerprint,
                sourceVolumeIdentifier: preflight.sourceVolume?.identifier,
                sourceVolumeName: preflight.sourceVolume?.name,
                operatorProfile: attributedProfile,
                algorithm: draftAlgorithm,
                verificationProfile: draftVerificationProfile
            )
            if !draftShootingDay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draftCameraLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !draftCardLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                productStore.updateTaskOrganization(
                    taskID: session.id,
                    projectID: selectedProjectID,
                    shootingDay: draftShootingDay,
                    cameraLabel: draftCameraLabel,
                    // Each task's own reel — the one its folder is named after.
                    cardLabel: draftCatalogReel(for: preflight.source)
                )
            }
            session.showLog = autoShowLog
            configureCallbacks(for: session)
            sessions.append(session)
            recents.noteTransfer(source: preflight.source, destinations: draftDestinations)
        }
        recentSources = recents.sources()
        recentDestinations = recents.destinations()
        draftAttemptKind = .copy
        draftParentAttemptID = nil
        withoutPageAnimation { showingNewOffload = false }
        notifier.prepare()
        scheduleQueued()
        refreshDock()
    }

    /// The reviewed plan's selection still matches what the draft asks for.
    /// `nil` on both sides means the whole source, which is also a match.
    private func selectionIsCurrent(_ preflight: TransferPreflight) -> Bool {
        let requested = draftSelection(for: preflight.source)
        guard let requested else { return preflight.includedRelativePaths == nil }
        guard let reviewed = preflight.includedRelativePaths else { return false }
        // Preflight expands a selected folder into its files, so the reviewed
        // set covers the request rather than equalling it.
        return requested.allSatisfy { entry in
            reviewed.contains(entry) || reviewed.contains { $0.hasPrefix(entry + "/") }
        }
    }

    func resume(_ pausedSession: TransferSession) {
        // A paused attempt is resumed once. A second resume would run after
        // the first and collide with every file the first one published.
        if let refusal = continuationRefusal(continuation(of: pausedSession.id)) {
            productStore.reportError(refusal)
            return
        }
        let manifest: TransferManifest
        do {
            manifest = try resumeManifest(for: pausedSession)
        } catch {
            productStore.reportError(error.localizedDescription)
            return
        }
        guard let scope = Self.resumeScope(
            pausedScope: pausedSession.includedRelativePaths,
            pausedFingerprint: pausedSession.sourceFingerprint,
            manifest: manifest
        ) else {
            productStore.reportError(L10n.text("The paused attempt's reviewed file scope cannot be confirmed; it cannot be resumed safely."))
            return
        }
        let session = TransferSession(
            taskID: pausedSession.taskID,
            parentAttemptID: pausedSession.id,
            attemptKind: .resume,
            label: pausedSession.label,
            source: pausedSession.source,
            destinations: zip(pausedSession.destinationBases, pausedSession.destinations).map {
                TransferDestination(baseRoot: $0.0, outputRoot: $0.1)
            },
            algorithm: pausedSession.algorithm,
            verificationProfile: pausedSession.verificationProfile,
            operatorProfile: productStore.activeProfile,
            projectID: pausedSession.projectID,
            sourceFingerprint: scope.sourceFingerprint,
            allowSameVolume: pausedSession.allowSameVolume,
            resumeManifest: manifest,
            // Exactly the paused attempt's reviewed items: a selection resumes
            // the selection, never the folder around it.
            includedRelativePaths: scope.includedRelativePaths
        )
        continuations.claim(session.destinations, of: pausedSession.id, by: session.id)
        session.showLog = UserDefaults.standard.bool(forKey: "prefs.autoShowLog")
        configureCallbacks(for: session)
        if let index = sessions.firstIndex(where: { $0.id == pausedSession.id }) {
            sessions.insert(session, at: index + 1)
        } else {
            sessions.append(session)
        }
        notifier.prepare()
        scheduleQueued()
        refreshDock()
    }

    /// The paused record a Resume builds on. Only this attempt's own paused
    /// manifest qualifies, and only while its source is present and every
    /// destination it paused on still holds that same record. A drive mounted
    /// at the same path is not proof of identity, and a resume trusts the
    /// files that drive already verified.
    func resumeManifest(for pausedSession: TransferSession) throws -> TransferManifest {
        guard pausedSession.report?.status == .paused,
              let manifestURL = pausedSession.manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ManifestWriter.decode(data),
              manifest.transferID == pausedSession.id.uuidString.lowercased(),
              manifest.status == TransferStatus.paused.rawValue
        else {
            throw ResumeRefusal(message: L10n.text("The paused attempt's manifest is unavailable; it cannot be resumed safely."))
        }
        guard FileManager.default.fileExists(atPath: pausedSession.source.path) else {
            throw ResumeRefusal(message: L10n.format(
                "Connect the source %@ to resume this transfer.",
                pausedSession.source.lastPathComponent
            ))
        }
        let recordName = ManifestWriter.manifestFileName(shortID: pausedSession.shortID)
        for destination in pausedSession.destinations {
            let record = (try? Data(contentsOf: destination.appendingPathComponent(recordName)))
                .flatMap { try? ManifestWriter.decode($0) }
            guard record?.transferID == manifest.transferID, record?.status == manifest.status else {
                throw ResumeRefusal(message: L10n.format(
                    "Resume needs every destination this transfer paused on. Reconnect %@, or use Retry as New Offload.",
                    pausedSession.baseDestination(for: destination).lastPathComponent
                ))
            }
        }
        return manifest
    }

    /// What a resume of a paused attempt may transfer: exactly the paused
    /// attempt's reviewed items, under the fingerprint the engine compared at
    /// pause time. `nil` when that cannot be proven; the resume is refused.
    ///
    /// A whole-source attempt stays whole-source. The engine re-enumerates the
    /// card and its fingerprint gate refuses any change, including a clip shot
    /// during the pause. Narrowing it to the paused item list would leave such
    /// a clip behind under a Verified verdict.
    nonisolated static func resumeScope(
        pausedScope: Set<String>?,
        pausedFingerprint: String?,
        manifest: TransferManifest
    ) -> ResumeScope? {
        // The session and its own evidence must agree on the reviewed plan.
        if let recorded = manifest.sourceFingerprint, let pausedFingerprint,
           recorded != pausedFingerprint {
            return nil
        }
        // Without the plan's identity nothing could refuse a widened plan.
        guard let fingerprint = manifest.sourceFingerprint ?? pausedFingerprint else { return nil }
        guard let pausedScope else {
            return ResumeScope(includedRelativePaths: nil, sourceFingerprint: fingerprint)
        }
        // A paused manifest lists every planned item, attempted or not, so it
        // must be exactly the selection.
        guard !pausedScope.isEmpty,
              Set(manifest.items.map(\.relativePath)) == pausedScope
        else { return nil }
        return ResumeScope(includedRelativePaths: pausedScope, sourceFingerprint: fingerprint)
    }

    // MARK: - Linked attempts

    func continuation(of attemptID: UUID) -> ContinuationAvailability {
        continuations.availability(of: attemptID)
    }

    /// Failed pairs a repair could still claim from this attempt's card.
    func retryableFailedPairCount(for session: TransferSession) -> Int {
        guard let report = session.report else { return 0 }
        return Self.retryableFailedPairCount(
            in: report, destinations: session.destinations,
            availability: continuation(of: session.id)
        )
    }

    nonisolated static func retryableFailedPairCount(
        in report: TransferReport, destinations: [URL], availability: ContinuationAvailability
    ) -> Int {
        repairableDestinations(destinations, availability: availability)
            .reduce(0) { $0 + failedRelativePaths(in: report, at: $1).count }
    }

    /// Destinations a repair may still be created for: those no linked
    /// attempt has taken over.
    nonisolated static func repairableDestinations(
        _ destinations: [URL], availability: ContinuationAvailability
    ) -> [URL] {
        switch availability {
        case .open: destinations
        case .continued(let claimed): destinations.filter { !claimed.contains($0) }
        }
    }

    nonisolated static func failedRelativePaths(in report: TransferReport, at destination: URL) -> Set<String> {
        Set(report.items.compactMap { item -> String? in
            if case .failed = item.outcomes[destination] { return item.item.relativePath }
            return nil
        })
    }

    /// Why no resume or repair may be created from this card, or `nil`.
    private func continuationRefusal(_ availability: ContinuationAvailability) -> String? {
        guard case .continued = availability else { return nil }
        return L10n.text("A linked attempt already continues this one. Use that attempt's card instead.")
    }

    private func configureCallbacks(for session: TransferSession) {
        session.onStarted = { [weak self, weak session] in
            guard let self, let session else { return }
            self.productStore.registerAttempt(
                id: session.id,
                taskID: session.taskID,
                parentAttemptID: session.parentAttemptID,
                kind: session.attemptKind,
                algorithm: session.algorithm,
                verificationProfile: session.verificationProfile,
                operatorProfile: session.operatorProfile
            )
        }
        session.onFinished = { [weak self, weak session] in
            guard let self else { return }
            if let session, let report = session.report {
                self.productStore.finishAttempt(
                    id: session.id,
                    taskID: session.taskID,
                    report: report,
                    verificationProfile: session.verificationProfile
                )
                // A resume or repair the engine stopped before any destination
                // hands its parent's Resume or Retry back.
                self.continuations.settle(child: session.id, with: report)
                self.notifier.notify(about: report, sourceName: session.displayName)
                if report.status == .verified,
                   UserDefaults.standard.bool(forKey: Self.automaticContactSheetKey) {
                    Task { await self.generateContactSheet(for: session) }
                }
            }
            self.scheduleQueued()
            self.refreshDock()
        }
    }

    func generateContactSheet(for session: TransferSession) async {
        guard let report = session.report, report.status == .verified else { return }
        if let existing = session.contactSheetURL {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            return
        }
        let generatingMessage = L10n.text("Generating contact sheet…")
        guard session.contactSheetMessage != generatingMessage else { return }
        session.updateContactSheet(url: nil, message: generatingMessage)
        let actor = productStore.activeProfile
        do {
            let data = try await ContactSheetService.generate(report: report, label: session.label)
            let locations = try await Task.detached(priority: .utility) {
                try ContactSheetService.write(data, report: report)
            }.value
            let url = locations.first
            session.updateContactSheet(
                url: url,
                message: L10n.format(
                    "Contact sheet created at %lld evidence locations.",
                    Int64(locations.count)
                )
            )
            productStore.recordAudit(AuditEventRecord(
                taskID: session.taskID,
                attemptID: session.id,
                actorKind: .operatorProfile,
                operatorSnapshot: OperatorSnapshot(profile: actor),
                action: .contactSheetCreated,
                detail: url?.path
            ))
        } catch {
            session.updateContactSheet(
                url: nil,
                message: L10n.format("Contact sheet was not created: %@", error.localizedDescription)
            )
        }
    }

    func verifyExisting(referenceURL: URL, mediaRoot: URL) async throws -> TransferReport {
        let id = UUID()
        let profile = productStore.activeProfile
        let reference = try VerificationReference.load(from: referenceURL)
        productStore.registerTask(
            id: id,
            label: "Verify \(mediaRoot.lastPathComponent)",
            source: mediaRoot,
            destinations: [mediaRoot],
            projectID: selectedProjectID,
            algorithm: reference.algorithm,
            verificationProfile: .standard
        )
        productStore.registerAttempt(
            id: id,
            taskID: id,
            kind: .verification,
            algorithm: reference.algorithm,
            verificationProfile: .standard,
            operatorProfile: profile
        )
        do {
            let report = try await StandaloneVerificationService.verify(
                id: id,
                referenceURL: referenceURL,
                mediaRoot: mediaRoot,
                operatorProfile: profile,
                projectID: selectedProjectID,
                spoolDirectory: TransferSession.spoolDirectory
            )
            productStore.finishAttempt(
                id: id,
                taskID: id,
                report: report,
                verificationProfile: .standard
            )
            return report
        } catch {
            productStore.reportError(L10n.format("Standalone verification failed: %@", error.localizedDescription))
            throw error
        }
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

    func benchmarkResult(for destination: URL) -> DestinationBenchmarkResult? {
        destinationBenchmarks[destination.standardizedFileURL.path]
    }

    func isBenchmarking(_ destination: URL) -> Bool {
        benchmarkingDestinationPaths.contains(destination.standardizedFileURL.path)
    }

    func benchmarkDestination(_ destination: URL) {
        let path = destination.standardizedFileURL.path
        guard !benchmarkingDestinationPaths.contains(path) else { return }
        benchmarkingDestinationPaths.insert(path)
        Task {
            defer { benchmarkingDestinationPaths.remove(path) }
            do {
                let result = try await DestinationBenchmarkService.run(at: destination)
                destinationBenchmarks[path] = result
                if let data = try? JSONEncoder().encode(destinationBenchmarks) {
                    UserDefaults.standard.set(data, forKey: "destinationBenchmarks.v1")
                }
                if let saved = workflowLibrary.destinations.first(where: { $0.path == path }) {
                    workflowLibrary.refreshDestination(saved)
                }
            } catch {
                productStore.reportError(L10n.format("Destination benchmark failed: %@", error.localizedDescription))
            }
        }
    }

    func moveQueued(_ session: TransferSession, by offset: Int) {
        guard session.isQueued else { return }
        let queued = sessions.filter(\.isQueued)
        guard let queueIndex = queued.firstIndex(where: { $0.id == session.id }) else { return }
        let targetQueueIndex = queueIndex + offset
        guard queued.indices.contains(targetQueueIndex),
              let currentIndex = sessions.firstIndex(where: { $0.id == session.id }),
              let targetIndex = sessions.firstIndex(where: { $0.id == queued[targetQueueIndex].id })
        else { return }
        sessions.swapAt(currentIndex, targetIndex)
        scheduleQueued()
    }

    func prioritizeQueued(_ session: TransferSession) {
        guard session.isQueued else { return }
        let queued = sessions.filter(\.isQueued)
        guard let first = queued.first,
              first.id != session.id,
              let currentIndex = sessions.firstIndex(where: { $0.id == session.id }),
              let firstIndex = sessions.firstIndex(where: { $0.id == first.id })
        else { return }
        sessions.remove(at: currentIndex)
        sessions.insert(session, at: firstIndex)
        scheduleQueued()
    }

    private func persistDraft() {
        selectionStore.save(source: draftSource, destinations: draftDestinations)
    }
}
