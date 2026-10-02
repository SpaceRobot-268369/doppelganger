import Foundation
import Testing
@testable import Doppelganger

/// L5: Eject Source (ui-dashboard-3, app-orchestration-5). The action may
/// unmount only the verified card itself, still mounted at its recorded mount
/// point, while no other queued or running transfer uses that volume.
///
/// Synthetic snapshots only. The probe tests read volume metadata for a
/// scratch directory and never unmount anything; every `perform` call gets a
/// recording closure. TransferSession is not constructed: its init writes a
/// journal under Application Support.
struct SourceEjectGateTests {
    private static let mount = "/Volumes/EOS_DIGITAL"
    private static let cardA = "6F1C2A9E-3B7D-4E21-9C55-0A1B2C3D4E5F"
    private static let cardB = "0D9E8F7A-6B5C-4D3E-8F2A-1B0C9D8E7F6A"
    private static let thisAttempt = UUID()

    private static func card(
        _ identifier: String = cardA,
        mountPath: String = mount,
        removable: Bool = true,
        totalBytes: Int64? = 63_847_792_640
    ) -> FileSystemVolume {
        FileSystemVolume(
            identifier: identifier,
            name: "EOS_DIGITAL",
            mountPath: mountPath,
            fileSystem: "ExFAT",
            totalBytes: totalBytes,
            isRemovable: removable
        )
    }

    private static func claim(
        volumes: Set<String> = [cardA],
        paths: [String] = [mount],
        active: Bool = true,
        session: UUID = UUID()
    ) -> SourceEjectClaim {
        SourceEjectClaim(sessionID: session, isActive: active, volumeIdentifiers: volumes, paths: paths)
    }

    private static func gate(
        verdict: TransferStatus? = .verified,
        sourcePath: String = mount,
        recorded: FileSystemVolume? = card(),
        live: FileSystemVolume? = card(),
        claims: [SourceEjectClaim] = []
    ) -> SourceEjectEligibility {
        SourceEjectGate.evaluate(
            sessionID: thisAttempt,
            verdict: verdict,
            sourcePath: sourcePath,
            recorded: recorded,
            live: live,
            claims: claims
        )
    }

    // MARK: - Shape (rules kept from main)

    @Test func theVerifiedCardStillMountedAndUnusedCanBeEjected() {
        #expect(Self.gate() == .available)
    }

    @Test func onlyAVerifiedVerdictOffersEject() {
        let verdicts: [TransferStatus?] = [nil, .paused, .transferredPendingVerification, .failed, .cancelled]
        for verdict in verdicts {
            #expect(Self.gate(verdict: verdict) == .notOffered, "\(String(describing: verdict))")
        }
    }

    @Test func onlyARemovableWholeVolumeSourceOffersEject() {
        #expect(Self.gate(sourcePath: Self.mount + "/DCIM") == .notOffered)
        #expect(Self.gate(recorded: Self.card(removable: false)) == .notOffered)
        #expect(Self.gate(recorded: nil) == .notOffered)
    }

    // MARK: - Identity (ui-dashboard-3)

    @Test func aSameNamedCardAtTheRecordedMountPointIsNeverEjected() {
        let cardBNow = Self.card(Self.cardB)
        #expect(Self.gate(live: cardBNow) == .differentVolumeMounted)
        // Card B's own running offload must not become a wait-then-eject of card B.
        #expect(Self.gate(live: cardBNow, claims: [Self.claim(volumes: [Self.cardB])]) == .differentVolumeMounted)
    }

    @Test func aMatchingIdentifierOnDifferentMediaIsStillRefused() {
        #expect(Self.gate(live: Self.card(totalBytes: 127_865_454_592)) == .differentVolumeMounted)
        #expect(Self.gate(live: Self.card(removable: false)) == .differentVolumeMounted)
    }

    @Test func anEjectedOrPulledCardIsGone() {
        #expect(Self.gate(live: nil) == .sourceGone)
        // volume(at:) walks up from a missing mount point to the parent volume.
        let parent = FileSystemVolume(identifier: UUID().uuidString, name: "Macintosh HD", mountPath: "/System/Volumes/Data")
        #expect(Self.gate(live: parent) == .sourceGone)
    }

    @Test func aVolumeWithoutAUUIDIsNeverTrusted() {
        // RealFileSystem's fallback identifier is the mount path, which a same-named card shares.
        let pathIdentified = Self.card(Self.mount)
        #expect(Self.gate(recorded: pathIdentified, live: pathIdentified) == .identityUnverifiable)
        let blank = Self.card("")
        #expect(Self.gate(recorded: blank, live: blank) == .identityUnverifiable)
    }

    // MARK: - Other transfers (app-orchestration-5)

    @Test func anActiveTransferOnTheSameCardBlocksEject() {
        #expect(Self.gate(claims: [Self.claim()]) == .inUse(count: 1))
        #expect(Self.gate(claims: [Self.claim(), Self.claim()]) == .inUse(count: 2))
    }

    @Test func aTransferIsMatchedByPathWhenItsVolumeDidNotResolve() {
        #expect(Self.gate(claims: [Self.claim(volumes: [], paths: [Self.mount + "/DCIM/100CANON"])]) == .inUse(count: 1))
        // "EOS_DIGITAL 1" is a different mount point, not a child of EOS_DIGITAL.
        #expect(Self.gate(claims: [Self.claim(volumes: [], paths: [Self.mount + " 1/DCIM"])]) == .available)
    }

    @Test func finishedTransfersOtherVolumesAndThisAttemptDoNotBlock() {
        #expect(Self.gate(claims: [Self.claim(active: false)]) == .available)
        #expect(Self.gate(claims: [Self.claim(volumes: [Self.cardB], paths: ["/Volumes/RAID"])]) == .available)
        #expect(Self.gate(claims: [Self.claim(session: Self.thisAttempt)]) == .available)
    }

    // MARK: - Click time

    @Test func onlyAvailableEverReachesTheUnmount() {
        let refused: [SourceEjectEligibility] = [
            .notOffered, .identityUnverifiable, .sourceGone, .differentVolumeMounted, .inUse(count: 1),
        ]
        for eligibility in refused {
            var unmounted: [URL] = []
            let outcome = SourceEjectGate.perform(eligibility, mountPath: Self.mount) { unmounted.append($0) }
            #expect(unmounted.isEmpty, "\(eligibility)")
            #expect(outcome == .refused(eligibility))
        }

        var unmounted: [URL] = []
        let noMountPoint = SourceEjectGate.perform(.available, mountPath: nil) { unmounted.append($0) }
        #expect(noMountPoint == .refused(.notOffered))
        #expect(unmounted.isEmpty)

        let ejected = SourceEjectGate.perform(.available, mountPath: Self.mount) { unmounted.append($0) }
        #expect(ejected == .ejected)
        #expect(unmounted.map(\.path) == [Self.mount])
    }

    @Test func anUnmountErrorIsReportedAsAFailure() {
        struct Dissented: LocalizedError {
            var errorDescription: String? { "The volume is in use by Spotlight." }
        }
        let outcome = SourceEjectGate.perform(.available, mountPath: Self.mount) { _ in throw Dissented() }
        #expect(outcome == .failed("The volume is in use by Spotlight."))
        #expect(outcome.message == L10n.format("Could not eject source: %@", "The volume is in use by Spotlight."))
    }

    /// main reported "Source safely ejected." for whatever it unmounted.
    @Test func noRefusalSaysTheSourceWasEjected() {
        let ejected = SourceEjectOutcome.ejected.message
        let refused: [SourceEjectEligibility] = [
            .notOffered, .identityUnverifiable, .sourceGone, .differentVolumeMounted, .inUse(count: 1), .inUse(count: 3),
        ]
        for eligibility in refused {
            let message = SourceEjectOutcome.refused(eligibility).message
            #expect(!message.isEmpty)
            #expect(message != ejected, "\(eligibility)")
        }
    }

    // MARK: - Real probes (scratch directory, read-only)

    /// The platform behaviour the gate relies on: probing a mount point that
    /// no longer exists lands on the parent volume, never on a match.
    @Test func aMountPointThatNoLongerExistsResolvesAsGone() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-eject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountPoint = root.appendingPathComponent("EOS_DIGITAL", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let path = RealFileSystem().canonicalURL(mountPoint).path
        try FileManager.default.removeItem(at: mountPoint)

        let live = try RealFileSystem().volume(at: URL(fileURLWithPath: path, isDirectory: true))

        #expect(live.mountPath != path)
        #expect(Self.gate(sourcePath: path, recorded: Self.card(mountPath: path), live: live) == .sourceGone)
    }

    @Test func aRealMountPointHoldingAnotherVolumeIsNeverEjectable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-eject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try RealFileSystem().volume(at: root)
        let live = try RealFileSystem().volume(at: URL(fileURLWithPath: host.mountPath, isDirectory: true))
        try #require(live.mountPath == host.mountPath)
        #expect(SourceEjectGate.hasStableIdentity(live), "APFS reports a volume UUID")
        let recorded = FileSystemVolume(
            identifier: Self.cardA,
            name: live.name,
            mountPath: live.mountPath,
            totalBytes: live.totalBytes,
            isRemovable: true
        )

        #expect(Self.gate(sourcePath: live.mountPath, recorded: recorded, live: live) == .differentVolumeMounted)
    }

    // MARK: - Strings

    @Test func ejectRefusalsShipInSimplifiedChinese() throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans")
        )
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let keys = [
            "Not ejected: the verified source is no longer mounted.",
            "Not ejected: a different volume is now mounted where the verified source was.",
            "Not ejected: another transfer still uses this source.",
            "Not ejected: %lld other transfers still use this source.",
            "Not ejected: Doppelganger could not confirm this is the verified source volume.",
            "Source In Use",
            "Another queued or running transfer still uses this source volume. Eject becomes available when it finishes.",
        ]
        for key in keys {
            let value = catalog[key]
            #expect(value != nil && value != key, "zh-Hans: \(key)")
        }
        #expect(catalog["Not ejected: %lld other transfers still use this source."]?.contains("%lld") == true)
    }
}
