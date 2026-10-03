import Foundation
import Testing
@testable import Doppelganger

/// Review follow-up to L5 (lifecycle-semantics-ui-l10n-2): the Eject Source
/// gate a verified card evaluates on every render reads the volume watcher's
/// list, not volume or free-space metadata. These pin how a watched volume is
/// judged; the click-time path still re-reads the volume (SourceEjectGateTests).
///
/// Synthetic snapshots only; nothing is probed or unmounted.
struct SourceEjectRenderTests {
    private static let mount = "/Volumes/EOS_DIGITAL"
    private static let cardA = "6F1C2A9E-3B7D-4E21-9C55-0A1B2C3D4E5F"
    private static let cardB = "0D9E8F7A-6B5C-4D3E-8F2A-1B0C9D8E7F6A"
    private static let capacity: Int64 = 63_847_792_640
    private static let thisAttempt = UUID()

    private static let recorded = FileSystemVolume(
        identifier: cardA,
        name: "EOS_DIGITAL",
        mountPath: mount,
        fileSystem: "ExFAT",
        totalBytes: capacity,
        isRemovable: true
    )

    /// As the watcher lists a mounted volume: a trailing-slash URL.
    private static func watched(
        _ identifier: String? = cardA,
        path: String = mount,
        totalBytes: Int64 = capacity,
        removable: Bool = true
    ) -> MountedVolume {
        MountedVolume(
            url: URL(fileURLWithPath: path + "/", isDirectory: true),
            name: "EOS_DIGITAL",
            looksLikeCameraCard: true,
            totalBytes: totalBytes,
            isRemovable: removable,
            isEjectable: true,
            volumeIdentifier: identifier
        )
    }

    private static func gate(_ mounted: [MountedVolume], recorded: FileSystemVolume = recorded) -> SourceEjectEligibility {
        SourceEjectGate.evaluate(
            sessionID: thisAttempt,
            verdict: .verified,
            sourcePath: mount,
            recorded: recorded,
            live: TransferSession.watchedVolume(at: recorded.mountPath, among: mounted),
            claims: []
        )
    }

    @Test func theVerifiedCardTheWatcherStillListsCanBeEjected() {
        let live = TransferSession.watchedVolume(at: Self.mount, among: [Self.watched()])
        #expect(live?.identifier == Self.cardA)
        #expect(live?.mountPath == Self.mount)
        #expect(live?.totalBytes == Self.capacity)
        #expect(Self.gate([Self.watched()]) == .available)
    }

    @Test func aCardTheWatcherNoLongerListsIsGone() {
        #expect(TransferSession.watchedVolume(at: Self.mount, among: []) == nil)
        #expect(Self.gate([]) == .sourceGone)
        #expect(Self.gate([Self.watched(path: Self.mount + " 1")]) == .sourceGone)
        #expect(TransferSession.watchedVolume(at: nil, among: [Self.watched()]) == nil)
    }

    @Test func aSameNamedCardTheWatcherListsIsNeverEjected() {
        #expect(Self.gate([Self.watched(Self.cardB)]) == .differentVolumeMounted)
        // No UUID: identified by its mount path, as RealFileSystem falls back.
        #expect(TransferSession.watchedVolume(at: Self.mount, among: [Self.watched(nil)])?.identifier == Self.mount)
        #expect(Self.gate([Self.watched(nil)]) == .differentVolumeMounted)
        #expect(Self.gate([Self.watched(totalBytes: 127_865_454_592)]) == .differentVolumeMounted)
        #expect(Self.gate([Self.watched(removable: false)]) == .differentVolumeMounted)
    }

    /// The watcher reports an unknown capacity as zero; it stays unknown, so
    /// it matches only a recorded volume whose capacity was unknown too.
    @Test func anUnreportedCapacityStaysUnknown() {
        #expect(TransferSession.watchedVolume(at: Self.mount, among: [Self.watched(totalBytes: 0)])?.totalBytes == nil)
        #expect(Self.gate([Self.watched(totalBytes: 0)]) == .differentVolumeMounted)
        let unknownCapacity = FileSystemVolume(
            identifier: Self.cardA, name: "EOS_DIGITAL", mountPath: Self.mount, isRemovable: true
        )
        #expect(Self.gate([Self.watched(totalBytes: 0)], recorded: unknownCapacity) == .available)
    }
}
