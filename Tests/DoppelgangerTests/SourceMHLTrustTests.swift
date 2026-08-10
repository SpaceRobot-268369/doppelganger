import Foundation
import Testing
@testable import Doppelganger

struct SourceMHLTrustTests {
    @Test func validatedSourceHistoryReusesDigestsOnlyAfterAllIdentityChecks() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let firstDestination = try fixtures.makeDestination(named: "first")
        let onwardDestination = try fixtures.makeDestination(named: "onward")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: card))

        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [firstDestination],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        #expect(first.report.status == .verified)
        let copiedPlan = try RealFileSystem().enumerate(root: firstDestination)
        #expect(SourcePlanFingerprint.make(copiedPlan) == fingerprint)

        let onward = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: firstDestination,
            destinations: [onwardDestination],
            spool: fixtures.root.appendingPathComponent("onward-spool"),
            sourceFingerprint: fingerprint
        )

        #expect(onward.report.status == .verified)
        #expect(onward.logMessages.contains { $0.contains("Trusted source ASC MHL chain") })
    }

    @Test func brokenChainIsVisibleAndNeverTrusted() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let firstDestination = try fixtures.makeDestination(named: "first")
        let onwardDestination = try fixtures.makeDestination(named: "onward")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: card))
        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: card,
            destinations: [firstDestination],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        #expect(first.report.status == .verified)
        let history = firstDestination.appendingPathComponent(MHLWriter.directoryName)
        let chain = try MHLReader.validateChain(at: history)
        let generation = history.appendingPathComponent(try #require(chain.entries.last).path)
        var damaged = try Data(contentsOf: generation)
        damaged.append(0x0A)
        try damaged.write(to: generation, options: .atomic)

        let onward = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: firstDestination,
            destinations: [onwardDestination],
            spool: fixtures.root.appendingPathComponent("onward-spool"),
            sourceFingerprint: fingerprint
        )

        #expect(onward.report.status == .verified)
        #expect(onward.logMessages.contains { $0.contains("will not be reused") })
        #expect(!onward.logMessages.contains { $0.contains("Trusted source ASC MHL chain") })
    }
}
