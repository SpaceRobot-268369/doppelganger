import Foundation
import Testing
@testable import Doppelganger

/// engine-5 / G08: under the Maximum profile a source file the independent
/// pre-read cannot read fails only that item, typed `source-unreadable`,
/// exactly as Standard does in its copy pass. Readable footage is still
/// pre-read, copied and verified; only a vanished source root stops the
/// offload. Synthetic fixtures in a scratch directory only.
struct MaximumPreReadFailureTests {
    private struct World {
        let fixtures: FixtureBuilder
        let card: URL
        let destA: URL
        let destB: URL
        let spool: URL
        let fs: FailpointFileSystem
        let sourceBefore: [String: String]
    }

    private static let bad = "DCIM/100MEDIA/b.bin"

    private func makeWorld() throws -> World {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        return World(
            fixtures: fixtures,
            card: card,
            destA: try fixtures.makeDestination(named: "dest-a"),
            destB: try fixtures.makeDestination(named: "dest-b"),
            spool: fixtures.root.appendingPathComponent("spool"),
            fs: FailpointFileSystem(base: RealFileSystem()),
            sourceBefore: try fixtures.digestSnapshot(of: card)
        )
    }

    private func expectSourceUntouched(_ world: World) throws {
        #expect(try world.fixtures.digestSnapshot(of: world.card) == world.sourceBefore,
                "source must never be modified")
    }

    /// Nothing named for `name` (published, or a `.doppelganger-partial-…`
    /// staging file) exists anywhere under `root`.
    private func noTrace(of name: String, under root: URL) -> Bool {
        let enumerator = FileManager.default.enumerator(atPath: root.path)
        while let path = enumerator?.nextObject() as? String {
            if (path as NSString).lastPathComponent.hasSuffix(name) { return false }
        }
        return true
    }

    private static func slug(_ outcome: ItemDestinationOutcome?) -> String {
        switch outcome {
        case .verified?: "verified"
        case .verifiedDuplicate?: "verified-duplicate"
        case .transferredPendingVerification?: "pending"
        case .failed(let reason)?: "failed:\(reason.slug)"
        case .skipped(let reason)?: "skipped:\(reason.rawValue)"
        case nil: "missing"
        }
    }

    /// Port of repro_maximumUnreadableFileFailsOnlyThatItem: an open-time
    /// failure, the resume/retry path that skips preflight.
    @Test func unreadableFileFailsOnlyThatItem() async throws {
        let world = try makeWorld()
        world.fs.markUnreadable(pathSuffix: "card/" + Self.bad)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool,
            verificationProfile: .maximum)

        #expect(run.report.status == .failed)
        #expect(run.phases == [
            .enumerating, .preReadingSource, .copying, .verifying, .writingManifest, .done,
        ])
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination) == .verified)
            #expect(run.report.outcome("MISC/c.txt", at: destination) == .verified)
            guard case .failed(.sourceUnreadable)? = run.report.outcome(Self.bad, at: destination) else {
                let got = String(describing: run.report.outcome(Self.bad, at: destination))
                Issue.record("expected failed(source-unreadable) at \(destination.path), got \(got)")
                continue
            }
            #expect(noTrace(of: "b.bin", under: destination))
        }
        #expect(run.report.verifiedCount == 4)
        #expect(run.report.failedCount == 2)
        #expect(run.report.skippedCount == 0)
        #expect(run.report.items.first { $0.item.relativePath == Self.bad }?.sourceDigest == nil)
        // Per-file failures live in typed outcomes (as in Standard); the
        // transfer-level issue is reserved for a vanished source.
        #expect(!run.report.issues.contains { $0.contains("pre-read failed") })
        #expect(!run.report.issues.contains { $0.contains("Source changed") })
        let manifest = try EngineHarness.decodeManifest(at: world.destA, shortID: run.report.shortID)
        let record = try #require(manifest.items.first { $0.relativePath == Self.bad })
        #expect(record.digest == nil)
        #expect(record.results.count == 2)
        #expect(record.results.allSatisfy { $0.status == "failed" && $0.reason == "source-unreadable" })
        try expectSourceUntouched(world)
    }

    /// The case reachable from New Offload: preflight reads the first byte,
    /// the pre-read hits EIO partway through the clip.
    @Test func midFileReadErrorFailsOnlyThatItem() async throws {
        let world = try makeWorld()
        world.fs.injectReadError(pathSuffix: "card/" + Self.bad, afterBytes: 70_000)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool,
            verificationProfile: .maximum)

        #expect(run.report.status == .failed)
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination) == .verified)
            #expect(run.report.outcome("MISC/c.txt", at: destination) == .verified)
            guard case .failed(.sourceUnreadable(let detail))? = run.report.outcome(Self.bad, at: destination) else {
                let got = String(describing: run.report.outcome(Self.bad, at: destination))
                Issue.record("expected failed(source-unreadable) at \(destination.path), got \(got)")
                continue
            }
            #expect(detail.contains("injected read error"))
            #expect(noTrace(of: "b.bin", under: destination))
        }
        #expect(run.report.verifiedCount == 4)
        #expect(run.report.failedCount == 2)
        try expectSourceUntouched(world)
    }

    /// Only the pre-read hits the bad sector; a re-read would succeed.
    /// Maximum must not copy bytes it never independently hashed, and must
    /// not read the missing pre-read digest as a source change that ends the
    /// offload (c.txt comes after b.bin in plan order).
    @Test func transientPreReadFailureNeverCopiesUnhashedBytes() async throws {
        let world = try makeWorld()
        world.fs.injectReadError(pathSuffix: "card/" + Self.bad, afterBytes: 70_000, failingOpens: 1)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA, world.destB], spool: world.spool,
            verificationProfile: .maximum)

        #expect(run.report.status == .failed)
        for destination in [world.destA, world.destB] {
            #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: destination) == .verified)
            #expect(run.report.outcome("MISC/c.txt", at: destination) == .verified)
            guard case .failed(.sourceUnreadable)? = run.report.outcome(Self.bad, at: destination) else {
                let got = String(describing: run.report.outcome(Self.bad, at: destination))
                Issue.record("expected failed(source-unreadable) at \(destination.path), got \(got)")
                continue
            }
            #expect(noTrace(of: "b.bin", under: destination))
        }
        #expect(run.report.verifiedCount == 4)
        #expect(run.report.failedCount == 2)
        #expect(run.report.items.first { $0.item.relativePath == Self.bad }?.sourceDigest == nil)
        #expect(!run.report.issues.contains { $0.contains("Source changed") })
        #expect(!run.logMessages.contains { $0.contains("source changed during transfer") })
        try expectSourceUntouched(world)
    }

    /// Maximum is stricter than Standard; it must never rescue less footage
    /// or record a different typed outcome for the same unreadable file.
    @Test func maximumRecordsTheSameOutcomesAsStandardForAnUnreadableFile() async throws {
        var maps: [[String: String]] = []
        for profile in [VerificationProfile.standard, .maximum] {
            let world = try makeWorld()
            world.fs.injectReadError(pathSuffix: "card/" + Self.bad, afterBytes: 70_000)
            let run = try await EngineHarness.run(
                fileSystem: world.fs, source: world.card,
                destinations: [world.destA, world.destB], spool: world.spool,
                verificationProfile: profile)
            #expect(run.report.status == .failed, "\(profile)")
            var map: [String: String] = [:]
            for item in run.report.items {
                for destination in [world.destA, world.destB] {
                    map["\(destination.lastPathComponent)/\(item.item.relativePath)"] =
                        Self.slug(item.outcomes[destination])
                }
            }
            maps.append(map)
            try expectSourceUntouched(world)
        }
        #expect(maps.count == 2 && maps[0] == maps[1])
        #expect(maps.last?["dest-a/\(Self.bad)"] == "failed:source-unreadable")
        #expect(maps.last?["dest-b/MISC/c.txt"] == "verified")
    }

    /// Port of repro_maximumUnreadableFileLeavesRetryableFailedPair, extended
    /// through the repair: exactly one failed pair (what retryFailures
    /// collects), and a Maximum retry repairs it once the sector reads.
    @Test func unreadableFileLeavesOneRetryablePairThatRepairs() async throws {
        let world = try makeWorld()
        world.fs.injectReadError(pathSuffix: "card/" + Self.bad, afterBytes: 70_000, failingOpens: 1)

        let parent = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA], spool: world.spool,
            verificationProfile: .maximum)

        let failedPaths = Set(parent.report.items.compactMap { item -> String? in
            if case .failed = item.outcomes[world.destA] { return item.item.relativePath }
            return nil
        })
        #expect(failedPaths == [Self.bad])
        #expect(parent.report.skippedCount == 0)
        #expect(parent.report.outcome(Self.bad, at: world.destA) != .skipped(.sourceUnavailable))
        let parentManifest = try EngineHarness.decodeManifest(at: world.destA, shortID: parent.report.shortID)

        let repaired = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card, destinations: [world.destA],
            spool: world.fixtures.root.appendingPathComponent("retry-spool"),
            verificationProfile: .maximum,
            retryManifest: parentManifest,
            includedRelativePaths: [Self.bad])

        #expect(repaired.report.status == .verified)
        #expect(repaired.report.items.map(\.item.relativePath) == [Self.bad])
        #expect(try world.fixtures.bytes(at: world.destA.appendingPathComponent(Self.bad))
            == world.fixtures.bytes(at: world.card.appendingPathComponent(Self.bad)))
        // The parent never published b.bin, so nothing was set aside.
        #expect(!FileManager.default.fileExists(
            atPath: world.destA.appendingPathComponent(".doppelganger-failed").path))
        try expectSourceUntouched(world)
    }

    /// Port of repro_maximumPreReadSourceVanishingStillStopsTheOffload
    /// (a guard), tightened to typed outcomes.
    @Test func sourceVanishingDuringPreReadStillStopsTheOffload() async throws {
        let world = try makeWorld()
        // The card disappears partway through a.bin's pre-read.
        world.fs.markVolumeGoneAfterReading(bytes: 100_000, under: world.card)

        let run = try await EngineHarness.run(
            fileSystem: world.fs, source: world.card,
            destinations: [world.destA], spool: world.spool,
            verificationProfile: .maximum)

        #expect(run.report.status == .failed)
        #expect(run.report.verifiedCount == 0)
        #expect(run.report.outcome("DCIM/100MEDIA/a.bin", at: world.destA) == .failed(.sourceUnmounted))
        #expect(run.report.outcome(Self.bad, at: world.destA) == .skipped(.sourceUnavailable))
        #expect(run.report.outcome("MISC/c.txt", at: world.destA) == .skipped(.sourceUnavailable))
        #expect(run.report.issues.contains {
            $0.hasPrefix("Maximum source pre-read failed at DCIM/100MEDIA/a.bin")
        })
        for spec in EngineHarness.standardFiles {
            #expect(!FileManager.default.fileExists(
                atPath: world.destA.appendingPathComponent(spec.path).path))
        }
        #expect(run.report.manifestLocations.contains(world.destA))
        try expectSourceUntouched(world)
    }
}
