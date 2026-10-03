import Foundation
import Testing
@testable import Doppelganger

/// A destination tile is green only when the whole transfer verified and its
/// evidence landed at that destination. Synthetic reports pin the rule; real
/// engine runs against scratch fixtures pin the report shapes it reads. No
/// `TransferSession` is constructed: its init writes a journal under
/// Application Support.
struct DestinationTileStateTests {
    private static let destinationA = ReportFixtures.destinationA
    private static let destinationB = ReportFixtures.destinationB
    private static let spool = URL(fileURLWithPath: "/Volumes/Spool/aaaaaaaa", isDirectory: true)
    private static let mismatch = ItemDestinationOutcome.failed(
        .checksumMismatch(expected: "00", actual: "11"))

    /// One item per index; `a[i]` and `b[i]` are that item's outcomes. Evidence
    /// lands at both destinations and the spool unless stated otherwise.
    private static func report(
        _ status: TransferStatus,
        a: [ItemDestinationOutcome],
        b: [ItemDestinationOutcome],
        evidenceAt manifestLocations: [URL]? = nil,
        issues: [String] = []
    ) -> TransferReport {
        precondition(a.count == b.count, "one outcome per item at each destination")
        return TransferReport(
            id: ReportFixtures.transferID,
            status: status,
            algorithm: .xxh3,
            sourceRoot: ReportFixtures.source,
            destinations: [destinationA, destinationB],
            startedAt: ReportFixtures.started,
            finishedAt: ReportFixtures.finished,
            items: zip(a, b).enumerated().map { index, pair in
                ItemResult(
                    item: SourceItem(relativePath: "CLIP\(index).MOV", size: 100),
                    sourceDigest: "00",
                    outcomes: [destinationA: pair.0, destinationB: pair.1]
                )
            },
            manifestLocations: manifestLocations ?? [destinationA, destinationB, spool],
            issues: issues
        )
    }

    private static func state(_ report: TransferReport, at destination: URL) -> TransferSession.DestinationState {
        TransferSession.terminalDestinationState(of: report, at: destination)
    }

    // MARK: - Transfer-level failure never draws green

    @Test(arguments: [
        "The source could not be scanned after the transfer.",
        "The source file list changed before the transfer finished.",
        "Could not write a complete ASC MHL generation: synthetic failure",
        "Could not write complete transfer evidence to: /Volumes/Shuttle/day01",
    ])
    func failedVerdictWithEveryPairVerifiedIsNotGreen(issue: String) {
        // The engine fails these runs without touching a pair outcome; an ASC
        // MHL rollback even leaves the (failed) records at every destination.
        let report = Self.report(.failed, a: [.verified, .verified], b: [.verified, .verifiedDuplicate],
                                 issues: [issue])
        #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func cancelWhileFinalizingIsNotGreen() {
        let report = Self.report(.cancelled, a: [.verified, .verified], b: [.verified, .verified])
        #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func healthyDestinationOfAPartiallyFailedTransferIsNotGreen() {
        // Partial failure is failure: no MHL is written anywhere and every
        // record says failed, so the clean drive cannot use the success look.
        let report = Self.report(.failed, a: [.verified, .verified], b: [.verified, Self.mismatch])
        #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(report, at: Self.destinationB) == .failed)
    }

    @Test func verifiedVerdictStillNeedsEvidenceAtThisDestination() {
        let report = Self.report(.verified, a: [.verified], b: [.verified],
                                 evidenceAt: [Self.destinationA, Self.spool])
        #expect(Self.state(report, at: Self.destinationA) == .verified)
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func pendingVerdictNeverPromotesVerifiedPairsToGreen() {
        let report = Self.report(.transferredPendingVerification,
                                 a: [.verifiedDuplicate, .verifiedDuplicate],
                                 b: [.transferredPendingVerification, .transferredPendingVerification])
        #expect(Self.state(report, at: Self.destinationA) == .pendingVerification)
        #expect(Self.state(report, at: Self.destinationB) == .pendingVerification)
    }

    /// The fail-closed invariant: no verdict but `.verified`, and no
    /// destination without evidence, ever yields the green state.
    @Test func noVerdictButVerifiedEverDrawsGreen() {
        let outcomeSets: [[ItemDestinationOutcome]] = [
            [],
            [.verified, .verified],
            [.verified, .verifiedDuplicate],
            [.verifiedDuplicate, .verifiedDuplicate],
            [.transferredPendingVerification, .transferredPendingVerification],
            [.verified, .transferredPendingVerification],
            [.verified, .skipped(.cancelled)],
            [.verified, .skipped(.paused)],
            [.verified, Self.mismatch],
        ]
        let evidence: [[URL]] = [[Self.destinationA, Self.destinationB, Self.spool], [Self.spool], []]
        let notVerified: [TransferStatus] = [.failed, .cancelled, .paused, .transferredPendingVerification]
        for status in notVerified {
            for outcomes in outcomeSets {
                for locations in evidence {
                    let report = Self.report(status, a: outcomes, b: outcomes, evidenceAt: locations)
                    for destination in [Self.destinationA, Self.destinationB] {
                        #expect(Self.state(report, at: destination) != .verified,
                                "\(status) · \(outcomes) · evidence at \(locations.map(\.lastPathComponent))")
                    }
                }
            }
        }
        for outcomes in outcomeSets {
            let report = Self.report(.verified, a: outcomes, b: outcomes, evidenceAt: [Self.spool])
            #expect(Self.state(report, at: Self.destinationA) != .verified, "verified · no evidence · \(outcomes)")
        }
    }

    // MARK: - What stays the same

    @Test func verifiedTransferWithEvidenceEverywhereIsGreen() {
        let fixture = ReportFixtures.verifiedReport()
        #expect(Self.state(fixture, at: Self.destinationA) == .verified)
        #expect(Self.state(fixture, at: Self.destinationB) == .verified)
        // A transfer-level warning on a verified verdict does not cost the
        // green: the gate is the verdict, not an empty issue list.
        let warned = Self.report(.verified, a: [.verified, .verifiedDuplicate], b: [.verified, .verified],
                                 issues: ["Warning: could not preserve source timestamps on 1 file(s) at /Volumes/Shuttle/day01"])
        #expect(Self.state(warned, at: Self.destinationA) == .verified)
        #expect(Self.state(warned, at: Self.destinationB) == .verified)
    }

    @Test func perPairStatesAreUnchanged() {
        let paused = Self.report(.paused, a: [.verified, .skipped(.paused)], b: [.verified, .verified])
        #expect(Self.state(paused, at: Self.destinationA) == .paused)
        #expect(Self.state(paused, at: Self.destinationB) == .paused)

        let fast = Self.report(.transferredPendingVerification,
                               a: [.transferredPendingVerification], b: [.transferredPendingVerification])
        #expect(Self.state(fast, at: Self.destinationA) == .pendingVerification)

        let cancelledMidCopy = Self.report(.cancelled, a: [.verified, .skipped(.cancelled)],
                                           b: [.skipped(.cancelled), .skipped(.cancelled)])
        #expect(Self.state(cancelledMidCopy, at: Self.destinationA) == .failed)
        #expect(Self.state(cancelledMidCopy, at: Self.destinationB) == .failed)

        let failedPair = Self.report(.failed, a: [Self.mismatch], b: [.verified])
        #expect(Self.state(failedPair, at: Self.destinationA) == .failed)

        let empty = Self.report(.failed, a: [], b: [])
        #expect(Self.state(empty, at: Self.destinationA) == .failed)

        // Fast copies that landed under a failed verdict are red like their
        // Standard analogue, never yellow; FastDestinationTileStateTests
        // covers the rest of the Fast gate.
        let fastFailed = Self.report(.failed, a: [.transferredPendingVerification], b: [Self.mismatch])
        #expect(Self.state(fastFailed, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(fastFailed, at: Self.destinationB) == .failed)
    }

    // MARK: - Real engine reports (scratch fixtures only)

    @Test func realEvidenceFailureReportDrawsNoGreenDestination() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.failEvidenceWrites(under: destB)

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"))

        // Engine half (also pinned by EngineFailureTests): every pair
        // verified, yet the transfer failed for an evidence reason.
        try #require(run.report.status == .failed)
        try #require(run.report.failedCount == 0)
        try #require(run.report.verifiedCount == EngineHarness.standardFiles.count * 2)
        #expect(run.report.manifestLocations.contains(destA))
        #expect(!run.report.manifestLocations.contains(destB))

        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .transferNotVerified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .transferNotVerified)
    }

    @Test func realSourceRescanVetoDrawsNoGreenDestination() async throws {
        // The card disappears after the copy, so the post-verify re-scan
        // fails. Every pair verified and the (failed) records landed at every
        // destination, so only the verdict keeps the tiles off green.
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.failListings(of: card, after: 1)

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"))

        try #require(run.report.status == .failed)
        try #require(run.report.issues.contains("The source could not be scanned after the transfer."))
        try #require(run.report.failedCount == 0)
        try #require(run.report.verifiedCount == EngineHarness.standardFiles.count * 2)
        #expect(run.report.manifestLocations.contains(destA))
        #expect(run.report.manifestLocations.contains(destB))

        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .transferNotVerified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .transferNotVerified)
    }

    @Test func realPartialFailureKeepsTheFailedDriveLoudest() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.corruptFirstByteOnWrite(pathSuffix: "dest-b/DCIM/100MEDIA/a.bin")

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"))

        try #require(run.report.status == .failed)
        try #require(run.report.items.allSatisfy { $0.outcomes[destA]?.isVerified == true })

        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .transferNotVerified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .failed)
    }

    @Test func realVerifiedReportIsGreenAtEveryDestination() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"))

        try #require(run.report.status == .verified)
        // The session keys tiles by the very URL values the engine records
        // evidence under. If that identity ever drifts, this fails instead of
        // every verified card quietly going red.
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .verified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .verified)
    }
}
