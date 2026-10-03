import Foundation
import IOKit
import Testing
@testable import Doppelganger

/// platform-io-db-4: copies are independent only when they live on different
/// physical devices. Two APFS volumes or partitions on one disk, or two shares
/// from one server, carry different volume UUIDs but one failure domain. No
/// test machine has those layouts, so these tests give scratch folders
/// synthetic identities through `FailpointFileSystem.overrideVolume(at:with:)`.
/// Synthetic fixtures only; the real-volume checks read metadata and nothing else.
struct VolumeIndependenceTests {
    private static let shuttleDisk = "disk:disk4@4242"
    private static let otherDisk = "disk:disk5@5005"
    private static let cardReader = "disk:disk9@9009"

    private static func volume(
        _ identifier: String,
        name: String,
        device: String?,
        mountPath: String = "/Volumes/Synthetic",
        removable: Bool = false
    ) -> FileSystemVolume {
        FileSystemVolume(
            identifier: identifier, name: name, mountPath: mountPath,
            availableBytes: 1 << 40, totalBytes: 1 << 41, // capacity never decides these tests
            isRemovable: removable, physicalDeviceIdentifier: device
        )
    }

    private struct World {
        let fixtures: FixtureBuilder
        let card: URL
        let shuttleA: URL
        let shuttleB: URL
        let fs: FailpointFileSystem

        func give(_ url: URL, _ volume: FileSystemVolume) { fs.overrideVolume(at: url, with: volume) }
    }

    private func makeWorld() throws -> World {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [.init("DCIM/100/A001.MOV", size: 4096, seed: 1)])
        let world = World(
            fixtures: fixtures,
            card: card,
            shuttleA: try fixtures.makeDestination(named: "Shuttle A"),
            shuttleB: try fixtures.makeDestination(named: "Shuttle B"),
            fs: FailpointFileSystem(base: RealFileSystem())
        )
        world.give(card, Self.volume("CARD-UUID", name: "A001", device: Self.cardReader))
        return world
    }

    private func inspect(_ world: World) async -> TransferPreflight {
        await TransferPreflight.inspect(
            source: world.card,
            destinationBases: [world.shuttleA, world.shuttleB],
            folderName: "20261002_A001",
            fileSystem: world.fs
        )
    }

    // MARK: - Preflight

    /// The finding's scenario: two APFS volumes on one SSD, or two shares on
    /// one NAS, picked as the two destinations.
    @Test(arguments: ["disk:disk4@4242", "net:nas.local"])
    func destinationsOnOnePhysicalDeviceNeedAcknowledgement(device: String) async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: device))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: device))

        let result = await inspect(world)

        #expect(result.canStart, "\(result.blockingIssues)")
        #expect(result.requiresAcknowledgement)
        #expect(result.warnings.contains {
            $0.contains("Shuttle A and Shuttle B") && $0.contains("share one physical volume")
        })
    }

    @Test func destinationOnTheSourcesPhysicalDeviceIsNotAnIndependentBackup() async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume("CARD-UUID", name: "A001", device: Self.shuttleDisk))
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: Self.shuttleDisk))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let result = await inspect(world)

        #expect(result.canStart, "\(result.blockingIssues)")
        #expect(result.requiresAcknowledgement)
        #expect(result.warnings.contains { $0.contains("Shuttle A is on the same physical device as the source") })
        #expect(!result.warnings.contains { $0.contains("Shuttle B") })
    }

    /// Formatting a card in camera rewrites the whole device, so a destination
    /// on another partition of the card is no backup at all.
    @Test func cameraCardCannotShareItsPhysicalDeviceWithADestination() async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume(
            "CARD-UUID", name: "A001", device: Self.cardReader,
            mountPath: world.fs.canonicalURL(world.card).path, removable: true))
        world.give(world.shuttleA, Self.volume("CARD-P2-UUID", name: "Shuttle A", device: Self.cardReader))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let result = await inspect(world)

        #expect(!result.canStart)
        #expect(result.blockingIssues.contains { $0.contains("cannot share its physical device") })
    }

    /// The same-volume wording each device check falls back to is unchanged:
    /// a block for a camera card, a warning for any other source.
    @Test(arguments: [false, true])
    func aDestinationOnTheSourceVolumeKeepsItsSameVolumeWording(cameraCard: Bool) async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume(
            "CARD-UUID", name: "A001", device: Self.cardReader,
            mountPath: world.fs.canonicalURL(world.card).path, removable: cameraCard))
        world.give(world.shuttleA, Self.volume("CARD-UUID", name: "A001", device: Self.cardReader))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let result = await inspect(world)

        if cameraCard {
            #expect(result.blockingIssues.contains("A camera-card source cannot also be its own destination volume."))
        } else {
            #expect(result.canStart, "\(result.blockingIssues)")
            #expect(result.warnings.contains(
                "Shuttle A is on the same volume as the source; this is not an independent backup."
            ))
        }
        #expect(!(result.blockingIssues + result.warnings).contains { $0.contains("physical device") })
    }

    /// Fail closed: a device the platform could not identify is never
    /// assumed independent.
    @Test func unidentifiedPhysicalDeviceNeedsAcknowledgement() async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: Self.shuttleDisk))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: nil))

        let result = await inspect(world)

        #expect(result.canStart, "\(result.blockingIssues)")
        #expect(result.requiresAcknowledgement)
        #expect(result.warnings.contains { $0.contains("Could not identify the physical device behind Shuttle B") })
        #expect(!result.warnings.contains { $0.contains("Shuttle A") })
    }

    /// Control: a card plus two separate SSDs adds no warning, so the
    /// acknowledgement keeps its meaning.
    @Test func separatePhysicalDevicesNeedNoAcknowledgement() async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: Self.shuttleDisk))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let result = await inspect(world)

        #expect(result.canStart, "\(result.blockingIssues)")
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        #expect(!result.requiresAcknowledgement)
    }

    // MARK: - Relation

    @Test func sharingIsDecidedByPhysicalDeviceNotVolumeUUID() {
        let a = Self.volume("A", name: "A", device: Self.shuttleDisk)
        let b = Self.volume("B", name: "B", device: Self.shuttleDisk)
        let c = Self.volume("C", name: "C", device: Self.otherDisk)
        let unknown = Self.volume("U", name: "U", device: nil)
        let sameUnknown = Self.volume("U", name: "U again", device: nil)

        #expect(a.sharesPhysicalDevice(with: b))
        #expect(!a.sharesPhysicalDevice(with: c))
        // Unknown is not proven shared; preflight warns about it separately.
        #expect(!a.sharesPhysicalDevice(with: unknown))
        // One logical volume always shares, whatever the device lookup said.
        #expect(unknown.sharesPhysicalDevice(with: sameUnknown))
    }

    // MARK: - Platform classification

    @Test func localMountsResolveToTheirWholePhysicalDisk() {
        // disk3 is an APFS container whose store is on disk2; disk4 holds two partitions.
        let layout = [
            "disk3s1": "disk2@100", "disk3s5": "disk2@100",
            "disk4s1": "disk4@200", "disk4s2": "disk4@200",
        ]
        func resolve(_ source: String) -> String? {
            RealFileSystem.physicalDeviceIdentifier(isLocal: true, mountedFrom: source) { layout[$0] }
        }
        #expect(resolve("/dev/disk3s1") == "disk:disk2@100")
        #expect(resolve("/dev/disk3s1") == resolve("/dev/disk3s5"))
        #expect(resolve("/dev/disk4s1") == resolve("/dev/disk4s2"))
        #expect(resolve("/dev/disk3s1") != resolve("/dev/disk4s1"))
        #expect(resolve("/dev/disk7s1") == nil) // disk image / virtual device: unknown
        #expect(resolve("map auto_home") == nil)
        #expect(resolve("devfs") == nil)
    }

    @Test func networkMountsResolveToTheirServerWithoutUserNames() {
        func resolve(_ source: String) -> String? {
            RealFileSystem.physicalDeviceIdentifier(isLocal: false, mountedFrom: source) { _ in nil }
        }
        #expect(resolve("//lucas@NAS.local/Shuttle A") == "net:nas.local")
        #expect(resolve("//nas.local/Shuttle%20B") == "net:nas.local")
        #expect(resolve("//WORKGROUP;lucas@nas.local:445/Dailies") == "net:nas.local")
        #expect(resolve("nas.local:/export/dailies") == "net:nas.local")
        #expect(resolve("https://dav.example.com/remote.php/dav") == "net:dav.example.com")
        #expect(resolve("//other-nas.local/Shuttle") != resolve("//nas.local/Shuttle"))
        #expect(resolve("//lucas@nas.local/x")?.contains("lucas") == false)
        #expect(resolve("map -hosts") == nil)
        #expect(resolve("") == nil)
    }

    // MARK: - Real scratch volume (metadata reads only)

    @Test func scratchFoldersOnOneVolumeAreNeverReportedIndependent() throws {
        let fixtures = try FixtureBuilder()
        let fs = RealFileSystem()
        let first = try fs.volume(at: try fixtures.makeDestination(named: "first"))
        let second = try fs.volume(at: try fixtures.makeDestination(named: "second"))

        #expect(first.physicalDeviceIdentifier == second.physicalDeviceIdentifier)
        #expect(first.sharesPhysicalDevice(with: second))
        // A virtual CI boot disk is honestly unknown; a real one is a whole disk.
        if let device = first.physicalDeviceIdentifier { #expect(device.hasPrefix("disk:")) }
    }

    /// The queue starts a transfer only while none of its resources is held
    /// by a running one (`AppModel.scheduleQueued`). Beside each volume they
    /// name the physical device behind it, so two volumes on one disk wait
    /// for each other. A recovered card is built because it never writes a
    /// journal.
    @MainActor
    @Test func queueResourcesNameThePhysicalDeviceBehindEachVolume() throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [.init("DCIM/100/A001.MOV", size: 4096, seed: 1)])
        let shuttle = try fixtures.makeDestination(named: "Shuttle")
        let scratch = try RealFileSystem().volume(at: shuttle)
        let session = TransferSession(interrupted: TransferJournal(
            id: UUID(),
            label: "20261002_A001",
            source: card,
            destinationBases: [shuttle],
            destinations: [shuttle.appendingPathComponent("20261002_A001", isDirectory: true)],
            algorithm: .xxh64,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: Date(),
            itemCount: 1,
            totalBytes: 4096,
            status: .interrupted
        ))

        // A virtual CI boot disk has no known device; then the volume alone.
        let expected = Set([scratch.identifier] + [scratch.physicalDeviceIdentifier].compactMap { $0 })
        #expect(session.resourceIDs == expected)
    }

    /// The key mapping itself, independent of this host's hardware: each
    /// volume contributes its identifier and, when known, its device; two
    /// volumes on one disk share the device key, and an unknown device adds
    /// nothing.
    @Test func queueResourcesAddEachKnownDeviceBesideItsVolume() {
        let card = FileSystemVolume(identifier: "card", name: "A001", mountPath: "/Volumes/A001", physicalDeviceIdentifier: "disk:disk4@11")
        let raidA = FileSystemVolume(identifier: "raid-a", name: "RAID A", mountPath: "/Volumes/RAID A", physicalDeviceIdentifier: "disk:disk6@42")
        let raidB = FileSystemVolume(identifier: "raid-b", name: "RAID B", mountPath: "/Volumes/RAID B", physicalDeviceIdentifier: "disk:disk6@42")
        let unknown = FileSystemVolume(identifier: "share", name: "Share", mountPath: "/Volumes/Share")

        #expect(TransferSession.queueResources(of: [card, raidA, raidB, unknown])
            == ["card", "disk:disk4@11", "raid-a", "raid-b", "disk:disk6@42", "share"])
        #expect(!TransferSession.queueResources(of: [raidA]).isDisjoint(with: TransferSession.queueResources(of: [raidB])),
                "two volumes on one disk hold one queue resource")
        #expect(TransferSession.queueResources(of: [unknown]) == ["share"])
    }

    @Test func unknownBSDNameHasNoPhysicalDisk() {
        #expect(RealFileSystem.wholePhysicalDisk(forBSDName: "doppelganger-no-such-disk") == nil)
    }

    /// The comparison above holds whatever the walk returns. This pins where
    /// it stops: the physical disk under the scratch volume's APFS container,
    /// never the container's synthesized whole disk, which would make two
    /// containers on one SSD look independent again. Checked against the IOKit
    /// provider chain read directly (metadata only).
    @Test func scratchVolumeResolvesToTheDiskBelowItsAPFSContainer() throws {
        let fixtures = try FixtureBuilder()
        let scratch = try fixtures.makeDestination(named: "scratch")
        var stats = statfs()
        try #require(statfs(scratch.path, &stats) == 0)
        let mountedFrom = withUnsafeBytes(of: stats.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        try #require(mountedFrom.hasPrefix("/dev/"), "scratch volume is not a local device: \(mountedFrom)")
        let chain = Self.providerChain(ofBSDName: String(mountedFrom.dropFirst("/dev/".count)))
        try #require(chain.contains { $0.isWholeMedia }, "no whole disk above \(mountedFrom): \(chain)")

        guard let resolved = RealFileSystem.physicalDeviceIdentifier(forPath: scratch.path) else {
            // Unknown is honest only for a disk image or a virtual boot disk.
            #expect(chain.contains { $0.isVirtual }, "a physical disk must resolve: \(chain)")
            return
        }
        let entryID = try #require(resolved.split(separator: "@").last.flatMap { UInt64($0) }, "\(resolved)")
        let index = try #require(chain.firstIndex { $0.registryID == entryID }, "\(resolved) is not above the volume")
        #expect(chain[index].isWholeMedia, "\(resolved) in \(chain)")
        #expect(!chain[index...].contains { $0.className.hasPrefix("AppleAPFS") }, "\(resolved) in \(chain)")
        #expect(!chain[(index + 1)...].contains { $0.isWholeMedia }, "\(resolved) in \(chain)")
    }

    private struct RegistryNode: CustomStringConvertible {
        let className: String
        let registryID: UInt64
        let isWholeMedia: Bool
        let isVirtual: Bool

        var description: String { "\(className)#\(registryID)\(isWholeMedia ? "(whole)" : "")" }
    }

    /// Every IOService provider from the node for `bsdName` up to the root.
    private static func providerChain(ofBSDName bsdName: String) -> [RegistryNode] {
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return [] }
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, matching) // consumes `matching`
        var chain: [RegistryNode] = []
        while entry != IO_OBJECT_NULL {
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &className)
            var registryID: UInt64 = 0
            _ = IORegistryEntryGetRegistryEntryID(entry, &registryID)
            let interconnect = (property(entry, "Protocol Characteristics") as? [String: Any])?["Physical Interconnect"]
            chain.append(RegistryNode(
                className: String(decoding: className.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                registryID: registryID,
                isWholeMedia: IOObjectConformsTo(entry, "IOMedia") != 0 && property(entry, "Whole") as? Bool == true,
                isVirtual: IOObjectConformsTo(entry, "AppleDiskImageDevice") != 0
                    || IOObjectConformsTo(entry, "IOHDIXHDDrive") != 0
                    || interconnect as? String == "Virtual Interface"
            ))
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = status == KERN_SUCCESS ? parent : IO_OBJECT_NULL
        }
        return chain
    }

    // MARK: - Localization

    static let independenceMessageKeys = [
        "A camera-card source cannot also be its own destination volume.",
        "A camera-card source cannot share its physical device with a destination.",
        "%@ is on the same volume as the source; this is not an independent backup.",
        "%@ is on the same physical device as the source; this is not an independent backup.",
        "%@ share one physical volume; they are not independent copies.",
        "Could not identify the physical device behind %@; the copies cannot be confirmed as independent.",
    ]

    /// Every independence message the review shows ships in Simplified
    /// Chinese and keeps its name placeholder.
    @Test(arguments: independenceMessageKeys)
    func independenceMessagesShipInSimplifiedChinese(key: String) throws {
        let bundle = Bundle(for: LocalizationBundleToken.self)
        let url = try #require(bundle.url(
            forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
        let catalog = try #require(NSDictionary(contentsOf: url) as? [String: String])

        let translation = try #require(catalog[key], "no zh-Hans entry for \(key)")
        #expect(translation != key)
        #expect(translation.components(separatedBy: "%@").count == key.components(separatedBy: "%@").count)
    }
}
