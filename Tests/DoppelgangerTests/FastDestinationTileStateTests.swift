import Foundation
import Testing
@testable import Doppelganger

/// Fast's yellow "Transferred · verification pending" tile has the same gate
/// as green: the transfer's own verdict says pending, and its evidence landed
/// at that destination. A Fast run the engine failed or cancelled after the
/// copy is red, like its Standard analogue. No `TransferSession` is
/// constructed: its init writes a journal under Application Support.
struct FastDestinationTileStateTests {
    private static let destinationA = ReportFixtures.destinationA
    private static let destinationB = ReportFixtures.destinationB
    private static let spool = URL(fileURLWithPath: "/Volumes/Spool/aaaaaaaa", isDirectory: true)
    private static let pending = ItemDestinationOutcome.transferredPendingVerification
    private static let mismatch = ItemDestinationOutcome.failed(
        .checksumMismatch(expected: "00", actual: "11"))

    /// One item per index; `a[i]` and `b[i]` are that item's outcomes. Evidence
    /// lands at both destinations and the spool unless stated otherwise.
    private static func report(
        _ status: TransferStatus,
        a: [ItemDestinationOutcome],
        b: [ItemDestinationOutcome],
        evidenceAt manifestLocations: [URL]? = nil
    ) -> TransferReport {
        precondition(a.count == b.count, "one outcome per item at each destination")
        return TransferReport(
            id: ReportFixtures.transferID,
            status: status,
            algorithm: .xxh3,
            verificationProfile: .fast,
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
            manifestLocations: manifestLocations ?? [destinationA, destinationB, spool]
        )
    }

    private static func state(_ report: TransferReport, at destination: URL) -> TransferSession.DestinationState {
        TransferSession.terminalDestinationState(of: report, at: destination)
    }

    private static func text(_ report: TransferReport, at destination: URL) -> String {
        TransferSession.transferNotVerifiedText(of: report, at: destination)
    }

    // MARK: - A failed or cancelled Fast run is red

    @Test(arguments: [TransferStatus.failed, .cancelled])
    func everyPairPendingUnderAFailedOrCancelledVerdictIsRed(status: TransferStatus) {
        // Evidence write failure, source re-scan veto, or Cancel while
        // finalizing: the engine leaves every Fast outcome pending.
        let report = Self.report(status, a: [Self.pending, Self.pending], b: [Self.pending, Self.pending])
        #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func pendingVerdictStillNeedsEvidenceAtThisDestination() {
        let report = Self.report(.transferredPendingVerification, a: [Self.pending], b: [Self.pending],
                                 evidenceAt: [Self.destinationA, Self.spool])
        #expect(Self.state(report, at: Self.destinationA) == .pendingVerification)
        #expect(Self.state(report, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func verifiedDuplicatesBesidePendingCopiesFollowTheVerdict() {
        // A Fast destination can hold proven duplicates beside copies that
        // still owe a read-back. Every pair landed, so the verdict decides —
        // never the "Incomplete" of a destination whose own pair failed.
        let pendingVerdict = Self.report(.transferredPendingVerification,
                                         a: [.verifiedDuplicate, Self.pending],
                                         b: [Self.pending, Self.pending])
        #expect(Self.state(pendingVerdict, at: Self.destinationA) == .pendingVerification)
        #expect(Self.state(pendingVerdict, at: Self.destinationB) == .pendingVerification)

        let failedVerdict = Self.report(.failed, a: [.verifiedDuplicate, Self.pending],
                                        b: [Self.pending, Self.pending])
        #expect(Self.state(failedVerdict, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(failedVerdict, at: Self.destinationB) == .transferNotVerified)
    }

    @Test func aDestinationWhoseOwnPairFailedStaysFailed() {
        let report = Self.report(.failed, a: [Self.pending, Self.pending], b: [Self.pending, Self.mismatch])
        #expect(Self.state(report, at: Self.destinationA) == .transferNotVerified)
        #expect(Self.state(report, at: Self.destinationB) == .failed)
    }

    /// The fail-closed invariant for yellow: only a pending verdict with
    /// evidence at this destination draws "verification pending", and only
    /// a verified verdict draws green.
    @Test func onlyAPendingVerdictWithEvidenceHereDrawsYellow() {
        let outcomeSets: [[ItemDestinationOutcome]] = [
            [],
            [Self.pending, Self.pending],
            [.verifiedDuplicate, Self.pending],
            [.verified, .verified],
            [Self.pending, .skipped(.cancelled)],
            [Self.pending, Self.mismatch],
        ]
        let evidence: [[URL]] = [[Self.destinationA, Self.destinationB, Self.spool], [Self.spool], []]
        let statuses: [TransferStatus] = [.failed, .cancelled, .paused, .verified, .transferredPendingVerification]
        for status in statuses {
            for outcomes in outcomeSets {
                for locations in evidence {
                    let report = Self.report(status, a: outcomes, b: outcomes, evidenceAt: locations)
                    for destination in [Self.destinationA, Self.destinationB] {
                        let state = Self.state(report, at: destination)
                        let context = "\(status) · \(outcomes) · evidence at \(locations.map(\.lastPathComponent))"
                        if state == .pendingVerification {
                            #expect(status == .transferredPendingVerification, "\(context)")
                            #expect(locations.contains(destination), "\(context)")
                        }
                        if state == .verified {
                            #expect(status == .verified, "\(context)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - The red text never says "verified" for bytes nobody read back

    @Test func redTextSaysVerifiedOnlyWhenEveryCopyHereWasReadBack() {
        let fast = Self.report(.failed, a: [Self.pending, Self.pending], b: [Self.pending, Self.pending])
        #expect(Self.text(fast, at: Self.destinationA) == L10n.text("Transferred · transfer not verified"))

        let mixed = Self.report(.cancelled, a: [.verifiedDuplicate, Self.pending], b: [Self.pending, Self.pending])
        #expect(Self.text(mixed, at: Self.destinationA) == L10n.text("Transferred · transfer not verified"))

        let readBack = Self.report(.failed, a: [.verified, .verifiedDuplicate], b: [.verified, Self.mismatch])
        #expect(Self.text(readBack, at: Self.destinationA) == L10n.text("Copies verified · transfer not verified"))
    }

    // MARK: - Real Fast engine reports (scratch fixtures only)

    @Test func realFastEvidenceFailureIsRedAtEveryDestination() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.failEvidenceWrites(under: destB)

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"),
            verificationProfile: .fast)

        // Engine half: every pair still pending, yet the transfer failed for
        // an evidence reason — including at the drive with no evidence.
        try #require(run.report.status == .failed)
        try #require(run.report.failedCount == 0)
        try #require(run.report.pendingVerificationCount == EngineHarness.standardFiles.count * 2)
        #expect(run.report.manifestLocations.contains(destA))
        #expect(!run.report.manifestLocations.contains(destB))

        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .transferNotVerified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .transferNotVerified)
        #expect(Self.text(run.report, at: destB) == L10n.text("Transferred · transfer not verified"))
    }

    @Test func realFastSourceRescanVetoIsRedAtEveryDestination() async throws {
        // The card disappears after the Fast metadata pass, so the post-copy
        // re-scan fails and the engine vetoes the run.
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")
        let fs = FailpointFileSystem(base: RealFileSystem())
        fs.failListings(of: card, after: 1)

        let run = try await EngineHarness.run(
            fileSystem: fs, source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"),
            verificationProfile: .fast)

        try #require(run.report.status == .failed)
        try #require(run.report.issues.contains("The source could not be scanned after the transfer."))
        try #require(run.report.failedCount == 0)
        try #require(run.report.pendingVerificationCount == EngineHarness.standardFiles.count * 2)
        #expect(run.report.manifestLocations.contains(destA))
        #expect(run.report.manifestLocations.contains(destB))

        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .transferNotVerified)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .transferNotVerified)
    }

    @Test func realFastReportIsYellowAtEveryDestination() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destA = try fixtures.makeDestination(named: "dest-a")
        let destB = try fixtures.makeDestination(named: "dest-b")

        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(), source: card, destinations: [destA, destB],
            spool: fixtures.root.appendingPathComponent("spool"),
            verificationProfile: .fast)

        try #require(run.report.status == .transferredPendingVerification)
        // Yellow now reads the evidence list too, keyed by the very URL
        // values the engine records it under; identity drift fails here.
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destA) == .pendingVerification)
        #expect(TransferSession.terminalDestinationState(of: run.report, at: destB) == .pendingVerification)
    }
}
