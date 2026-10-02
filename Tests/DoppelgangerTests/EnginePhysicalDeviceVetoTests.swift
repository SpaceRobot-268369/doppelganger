import Foundation
import Testing
@testable import Doppelganger

/// platform-io-db-4, engine side: the engine repeats the review's
/// independence check on physical devices, not only on volume UUIDs. Two
/// APFS volumes or partitions on one disk, or two shares from one server,
/// are one failure domain. A shared device needs the same acknowledgement as
/// a shared volume, and a camera card mounted as the source can never share
/// its device with a destination.
///
/// No test machine has those layouts, so scratch folders get synthetic
/// identities through `FailpointFileSystem.overrideVolume(at:with:)`.
/// Synthetic fixtures only (FixtureBuilder temp dir).
struct EnginePhysicalDeviceVetoTests {
    private static let shuttleDisk = "disk:disk4@4242"
    private static let otherDisk = "disk:disk5@5005"
    private static let cardReader = "disk:disk9@9009"
    private static let folderName = "20261002_A001"
    private static let clip = FixtureBuilder.FileSpec("DCIM/100/A001.MOV", size: 70_000, seed: 41)

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

        func output(of base: URL) -> URL {
            base.appendingPathComponent(EnginePhysicalDeviceVetoTests.folderName, isDirectory: true)
        }
    }

    private struct Run {
        let report: TransferReport
        let errors: [String]
    }

    private func makeWorld() throws -> World {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(named: "A001", files: [Self.clip])
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

    /// A fresh offload into a new task folder on each base, as
    /// `TransferSession.start()` builds it; `acknowledged` is the review's
    /// "not on independent volumes" acknowledgement.
    private func run(
        _ world: World,
        source: URL? = nil,
        to bases: [URL],
        acknowledged: Bool
    ) async throws -> Run {
        let engine = TransferEngine(
            fileSystem: world.fs,
            configuration: TransferConfiguration(chunkSize: 64 * 1024, progressInterval: .milliseconds(1))
        )
        let request = TransferRequest(
            sourceRoot: source ?? world.card,
            destinations: bases.map { TransferDestination(baseRoot: $0, outputRoot: world.output(of: $0)) },
            algorithm: .xxh3,
            spoolDirectory: world.fixtures.root.appendingPathComponent("spool-\(UUID().uuidString.prefix(8))"),
            allowSameVolume: acknowledged,
            requireNewOutputRoots: true
        )
        var report: TransferReport?
        var errors: [String] = []
        for await event in await engine.run(request) {
            if case .log(let entry) = event, entry.level == .error { errors.append(entry.message) }
            if case .finished(let finished) = event { report = finished }
        }
        return Run(report: try #require(report, "stream must end with .finished"), errors: errors)
    }

    /// A vetoed request never touches a destination: no task folder, no copy.
    private func expectUntouched(_ bases: [URL], in world: World) {
        for base in bases {
            #expect(!FileManager.default.fileExists(atPath: world.output(of: base).path), "\(base.lastPathComponent)")
        }
    }

    private func expectVerified(_ run: Run, at bases: [URL], in world: World) throws {
        #expect(run.report.status == .verified, "errors: \(run.errors) issues: \(run.report.issues)")
        for base in bases {
            let copy = world.output(of: base).appendingPathComponent(Self.clip.path)
            #expect(run.report.outcome(Self.clip.path, at: world.output(of: base)) == .verified)
            #expect(try world.fixtures.bytes(at: copy) == Self.clip.bytes)
        }
    }

    // MARK: - Source and destination

    /// The finding: the engine compared volume UUIDs only, so a destination
    /// on another APFS volume of the source's own disk (or another share of
    /// the source's server) started without the acknowledgement.
    @Test(arguments: ["disk:disk4@4242", "net:nas.local"])
    func aDestinationOnTheSourcesPhysicalDeviceNeedsAcknowledgement(device: String) async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume("CARD-UUID", name: "A001", device: device))
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: device))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let refused = try await run(world, to: [world.shuttleA, world.shuttleB], acknowledged: false)

        #expect(refused.report.status == .failed)
        #expect(refused.errors.contains(
            "Source and destination \(world.shuttleA.path) are on the same physical device. "
                + "Explicit acknowledgement is required."
        ), "\(refused.errors)")
        expectUntouched([world.shuttleA, world.shuttleB], in: world)

        let acknowledged = try await run(world, to: [world.shuttleA, world.shuttleB], acknowledged: true)
        try expectVerified(acknowledged, at: [world.shuttleA, world.shuttleB], in: world)
    }

    /// The same-volume wording is unchanged.
    @Test func aDestinationOnTheSourceVolumeKeepsItsSameVolumeVeto() async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("CARD-UUID", name: "A001", device: Self.cardReader))

        let refused = try await run(world, to: [world.shuttleA], acknowledged: false)

        #expect(refused.report.status == .failed)
        #expect(refused.errors.contains(
            "Source and destination \(world.shuttleA.path) are on the same volume. Explicit acknowledgement is required."
        ), "\(refused.errors)")
        expectUntouched([world.shuttleA], in: world)
    }

    // MARK: - Destinations

    @Test func twoDestinationsOnOnePhysicalDeviceNeedAcknowledgement() async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: Self.shuttleDisk))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.shuttleDisk))

        let refused = try await run(world, to: [world.shuttleA, world.shuttleB], acknowledged: false)

        #expect(refused.report.status == .failed)
        #expect(refused.errors.contains(
            "Two destinations share the same physical volume. Explicit acknowledgement is required."
        ), "\(refused.errors)")
        expectUntouched([world.shuttleA, world.shuttleB], in: world)

        let acknowledged = try await run(world, to: [world.shuttleA, world.shuttleB], acknowledged: true)
        try expectVerified(acknowledged, at: [world.shuttleA, world.shuttleB], in: world)
    }

    /// Control: a card plus two separate SSDs starts without the
    /// acknowledgement, so the veto did not widen to independent devices.
    @Test func separatePhysicalDevicesNeedNoAcknowledgement() async throws {
        let world = try makeWorld()
        world.give(world.shuttleA, Self.volume("SHUTTLE-A-UUID", name: "Shuttle A", device: Self.shuttleDisk))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let run = try await run(world, to: [world.shuttleA, world.shuttleB], acknowledged: false)

        try expectVerified(run, at: [world.shuttleA, world.shuttleB], in: world)
    }

    // MARK: - Camera card

    /// Formatting a card in camera rewrites the whole device, so a
    /// destination on another partition of the card is no backup, and no
    /// acknowledgement starts it. The same-volume case keeps its wording.
    @Test(arguments: [false, true])
    func aCameraCardCannotShareItsPhysicalDeviceEvenWhenAcknowledged(sameVolume: Bool) async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume(
            "CARD-UUID", name: "A001", device: Self.cardReader,
            mountPath: world.fs.canonicalURL(world.card).path, removable: true))
        world.give(world.shuttleA, Self.volume(
            sameVolume ? "CARD-UUID" : "CARD-P2-UUID", name: "Shuttle A", device: Self.cardReader))
        world.give(world.shuttleB, Self.volume("SHUTTLE-B-UUID", name: "Shuttle B", device: Self.otherDisk))

        let refused = try await run(world, to: [world.shuttleB, world.shuttleA], acknowledged: true)

        #expect(refused.report.status == .failed)
        #expect(refused.errors.contains(sameVolume
            ? "A removable source volume cannot also contain its destination."
            : "A removable source's physical device cannot also hold destination \(world.shuttleA.path)."
        ), "\(refused.errors)")
        expectUntouched([world.shuttleA, world.shuttleB], in: world)
    }

    /// Control: the unconditional block is keyed on the mounted card itself,
    /// as before. A folder chosen inside a removable volume that shares its
    /// device with a destination needs, and accepts, the acknowledgement.
    @Test func aFolderInsideARemovableVolumeOnTheSameDeviceNeedsOnlyAcknowledgement() async throws {
        let world = try makeWorld()
        world.give(world.card, Self.volume(
            "CARD-UUID", name: "A001", device: Self.cardReader,
            mountPath: world.fs.canonicalURL(world.card).path, removable: true))
        world.give(world.shuttleA, Self.volume("CARD-P2-UUID", name: "Shuttle A", device: Self.cardReader))
        let folder = world.card.appendingPathComponent("DCIM", isDirectory: true)

        let refused = try await run(world, source: folder, to: [world.shuttleA], acknowledged: false)
        #expect(refused.report.status == .failed)
        #expect(refused.errors.contains { $0.contains("are on the same physical device") }, "\(refused.errors)")
        expectUntouched([world.shuttleA], in: world)

        let acknowledged = try await run(world, source: folder, to: [world.shuttleA], acknowledged: true)
        #expect(acknowledged.report.status == .verified, "errors: \(acknowledged.errors)")
        #expect(try world.fixtures.bytes(
            at: world.output(of: world.shuttleA).appendingPathComponent("100/A001.MOV")) == Self.clip.bytes)
    }
}
