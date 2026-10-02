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

    private(set) var sessions: [TransferSession] = []
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
    private let notifier = TransferNotifier()
    private let dockProgress = DockProgressController()
    private var dockTimer: Timer?

    init(
        selectionStore: any SelectionStore = UserDefaultsSelectionStore(),
        recents: RecentsStore = RecentsStore(),
        productStore: ProductStore = ProductStore(),
        // Injectable so tests never run journal recovery against the real
        // spool, which rewrites unfinished journals and clears staging files.
        spoolRoot: URL = TransferSession.spoolDirectory
    ) {
        self.selectionStore = selectionStore
        self.recents = recents
        self.productStore = productStore
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
            draftName = TransferPreflight.defaultFolderName(for: source)
        }
        recentSources = recents.sources()
        recentDestinations = recents.destinations()
        if let data = defaults.data(forKey: "destinationBenchmarks.v1"),
           let saved = try? JSONDecoder().decode([String: DestinationBenchmarkResult].self, from: data) {
            destinationBenchmarks = saved
        }
        let journalStore = TransferJournalStore(root: spoolRoot)
        sessions = journalStore.recoverInterrupted().map(TransferSession.init(interrupted:))
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
        case .attention: sessions.filter(\.needsAttention)
        case .verified: sessions.filter { $0.report?.status == .verified }
        }
    }

    var activeCount: Int { sessions.filter(\.isActive).count }
    var completeCount: Int { sessions.count - activeCount }
    /// Shares `TransferSession.needsAttention` with the filter chip and the
    /// sidebar footer so the three never disagree about what is a problem.
    var attentionCount: Int { sessions.filter(\.needsAttention).count }
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
        draftName = reel.isEmpty ? "" : TransferPreflight.defaultFolderName(reel: reel)
    }

    /// Cascade and retry name their own output; everything else is derived.
    private func setExplicitDraftName(_ value: String) {
        draftName = value
    }

    var totalPlannedBytes: Int64 { sessions.reduce(0) { $0 + $1.planTotalBytes } }
    var aggregateThroughput: Double { sessions.reduce(0) { $0 + $1.throughputBytesPerSecond } }

    /// Quiet only while no session needs attention — a live failure, a failed
    /// or cancelled verdict, or a copy still awaiting verification flips the
    /// footer to a loud warning until its card is dismissed or verified.
    var systemNominal: Bool {
        !sessions.contains(where: \.needsAttention)
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
        presentNewOffload()
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

        var retries: [TransferSession] = []
        for destination in failedSession.destinations {
            let paths = Set(report.items.compactMap { item -> String? in
                if case .failed = item.outcomes[destination] { return item.item.relativePath }
                return nil
            })
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
            productStore.reportError(L10n.text("This attempt has no failed file/destination pairs to retry."))
            return
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

    /// The output folder name for one source. The primary source uses the
    /// reviewed reel; a batch's other sources use the reel their own name
    /// implies, defaulting to the next tape so two unnamed cards never resolve
    /// to one folder. Both follow the same `YYYYMMDD_REEL` convention.
    func draftFolderName(for source: URL) -> String {
        if source.standardizedFileURL == draftSource?.standardizedFileURL {
            return TransferPreflight.validFolderName(draftName)
        }
        let position = draftSources.firstIndex {
            $0.standardizedFileURL == source.standardizedFileURL
        } ?? 0
        return TransferPreflight.validFolderName(
            TransferPreflight.defaultFolderName(
                reel: TransferPreflight.reelName(for: source, position: position)
            )
        )
    }

    /// Every source in a batch writes into its own folder, so two sources that
    /// resolve to one name must block the review before preflight runs.
    var draftFolderNamesAreUnique: Bool {
        guard draftDestinationLayout == .newFolder else { return true }
        let names = draftSources.map { draftFolderName(for: $0) }
        return !names.contains(where: \.isEmpty) && Set(names).count == names.count
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
                    cardLabel: draftCardLabel
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
        guard pausedSession.report?.status == .paused,
              let manifestURL = pausedSession.manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ManifestWriter.decode(data)
        else {
            productStore.reportError(L10n.text("The paused attempt's manifest is unavailable; it cannot be resumed safely."))
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
            sourceFingerprint: manifest.sourceFingerprint ?? pausedSession.sourceFingerprint,
            allowSameVolume: pausedSession.allowSameVolume,
            resumeManifest: manifest
        )
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
