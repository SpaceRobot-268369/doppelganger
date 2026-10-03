import Foundation
import Testing
@testable import Doppelganger

struct TransferJournalStoreTests {
    @Test func unfinishedJournalIsRecoveredExactlyOnce() throws {
        let fixtures = try FixtureBuilder()
        let root = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let store = TransferJournalStore(root: root)
        let journal = TransferJournal(
            id: UUID(),
            label: "Day 01",
            source: fixtures.root.appendingPathComponent("source"),
            destinationBases: [fixtures.root.appendingPathComponent("drive")],
            destinations: [fixtures.root.appendingPathComponent("drive/Day 01")],
            algorithm: .xxh64,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: Date(),
            itemCount: 12,
            totalBytes: 3456,
            status: .running
        )
        store.save(journal)

        let destination = try #require(journal.destinations.first)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let staleManifest = destination.appendingPathComponent(
            ManifestWriter.manifestFileName(
                shortID: String(journal.id.uuidString.prefix(8)).lowercased()
            )
        )
        try Data("stale verified evidence".utf8).write(to: staleManifest)

        let firstRecovery = store.recoverInterrupted()
        #expect(firstRecovery.map(\.id) == [journal.id])
        #expect(firstRecovery.first?.itemCount == 12)
        #expect(!FileManager.default.fileExists(atPath: staleManifest.path))
        #expect(store.recoverInterrupted().isEmpty)
    }

    @Test func journalsWrittenBeforeGenerationTrackingStillRecover() throws {
        let fixtures = try FixtureBuilder()
        let root = fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let id = UUID()
        let shortID = String(id.uuidString.prefix(8)).lowercased()
        let directory = root.appendingPathComponent(shortID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The exact shape an older build wrote: no `mhlGenerations` key.
        let legacy = """
        {
          "algorithm" : "xxh64",
          "allowSameVolume" : true,
          "createdAt" : "2026-01-01T00:00:00Z",
          "destinationBases" : ["file:///tmp/drive/"],
          "destinations" : ["file:///tmp/drive/Day%2001/"],
          "id" : "\(id.uuidString)",
          "itemCount" : 3,
          "label" : "Day 01",
          "source" : "file:///tmp/card/",
          "status" : "finalizing",
          "totalBytes" : 351000
        }
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("transfer-journal.json"))

        let store = TransferJournalStore(root: root)
        let recovered = store.recoverInterrupted()
        #expect(recovered.map(\.id) == [id])
        #expect(recovered.first?.mhlGenerations == nil)
        #expect(store.recoverInterrupted().isEmpty)
    }

    /// Two real verified transfers into one destination, so the second one's
    /// generation sits on top of an archived one-entry chain.
    private struct GenerationWorld {
        let fixtures: FixtureBuilder
        let source: URL
        let destination: URL
        let directory: URL
        let firstGeneration: URL
        let secondRun: EngineHarness.Run
        let records: [MHLGenerationRecord]
        let chainBytesAfterSecond: Data
    }

    private func makeGenerationWorld() async throws -> GenerationWorld {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "drive/Day 01")
        let fingerprint = SourcePlanFingerprint.make(try RealFileSystem().enumerate(root: source))
        let first = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("first-spool"),
            sourceFingerprint: fingerprint
        )
        #expect(first.report.status == .verified)
        let manifest = try EngineHarness.decodeManifest(at: destination, shortID: first.report.shortID)
        let second = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("second-spool"),
            sourceFingerprint: fingerprint,
            duplicateManifests: [destination.path: manifest]
        )
        #expect(second.report.status == .verified)
        let records = second.events.compactMap { event -> MHLGenerationRecord? in
            guard case .mhlGenerationWritten(let destination, let generationURL, let chainURL, let archiveURL) = event
            else { return nil }
            return MHLGenerationRecord(
                destination: destination,
                generationURL: generationURL,
                chainURL: chainURL,
                archiveURL: archiveURL
            )
        }
        let directory = destination.appendingPathComponent(MHLWriter.directoryName)
        let firstRecord = first.events.compactMap { event -> URL? in
            guard case .mhlGenerationWritten(_, let generationURL, _, _) = event else { return nil }
            return generationURL
        }
        return GenerationWorld(
            fixtures: fixtures,
            source: source,
            destination: destination,
            directory: directory,
            firstGeneration: try #require(firstRecord.first),
            secondRun: second,
            records: records,
            chainBytesAfterSecond: try Data(contentsOf: directory.appendingPathComponent(MHLWriter.chainFileName))
        )
    }

    private func makeJournal(id: UUID, world: GenerationWorld, status: TransferJournal.Status) -> TransferJournal {
        var journal = TransferJournal(
            id: id,
            label: "Day 01",
            source: world.source,
            destinationBases: [world.fixtures.root.appendingPathComponent("drive")],
            destinations: [world.destination],
            algorithm: .xxh64,
            allowSameVolume: true,
            createdAt: Date(),
            startedAt: Date(),
            itemCount: 3,
            totalBytes: 351_000,
            status: status
        )
        journal.mhlGenerations = world.records
        return journal
    }

    @Test func engineReportsEachGenerationBeforeFinishing() async throws {
        let world = try await makeGenerationWorld()
        #expect(world.records.count == 1)
        let record = try #require(world.records.first)
        #expect(record.destination == world.destination)
        #expect(record.generationURL.lastPathComponent.hasPrefix("0002_"))
        #expect(record.chainURL == world.directory.appendingPathComponent(MHLWriter.chainFileName))
        #expect(record.archiveURL == world.directory
            .appendingPathComponent("chain-history")
            .appendingPathComponent("ascmhl_chain_before_0002.xml"))
        let eventOrder = world.secondRun.events.compactMap { event -> String? in
            switch event {
            case .mhlGenerationWritten: "generation"
            case .finished: "finished"
            default: nil
            }
        }
        #expect(eventOrder == ["generation", "finished"])
    }

    @Test func interruptedFinalizationRollsBackTheOrphanedGeneration() async throws {
        let world = try await makeGenerationWorld()
        let record = try #require(world.records.first)
        let archived = try Data(contentsOf: try #require(record.archiveURL))
        #expect(archived != world.chainBytesAfterSecond)

        // The process died after the append but before the terminal verdict:
        // the journal still says finalizing and remembers the generation.
        let root = world.fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let store = TransferJournalStore(root: root)
        let journal = makeJournal(id: UUID(), world: world, status: .finalizing)
        store.save(journal)

        let recovered = store.recoverInterrupted()
        #expect(recovered.map(\.id) == [journal.id])

        #expect(!FileManager.default.fileExists(atPath: record.generationURL.path))
        #expect(FileManager.default.fileExists(atPath: world.firstGeneration.path))
        #expect(try Data(contentsOf: record.chainURL) == archived)
        let chain = try MHLReader.validateChain(at: world.directory)
        #expect(chain.entries.map(\.sequence) == [1])
        #expect(chain.entries.first?.path == world.firstGeneration.lastPathComponent)
        // Copied media is never touched by recovery.
        for spec in EngineHarness.standardFiles {
            #expect(try world.fixtures.bytes(at: world.destination.appendingPathComponent(spec.path)) == spec.bytes)
        }
        #expect(store.recoverInterrupted().isEmpty)
    }

    @Test func terminalJournalLeavesItsGenerationAlone() async throws {
        let world = try await makeGenerationWorld()
        let record = try #require(world.records.first)
        let root = world.fixtures.root.appendingPathComponent("spool", isDirectory: true)
        let store = TransferJournalStore(root: root)
        store.save(makeJournal(id: UUID(), world: world, status: .verified))

        #expect(store.recoverInterrupted().isEmpty)
        #expect(FileManager.default.fileExists(atPath: record.generationURL.path))
        #expect(try Data(contentsOf: record.chainURL) == world.chainBytesAfterSecond)
        #expect(try MHLReader.validateChain(at: world.directory).entries.map(\.sequence) == [1, 2])
    }

    @Test func rollbackRefusesWhenALaterGenerationWasAppended() async throws {
        let world = try await makeGenerationWorld()
        let record = try #require(world.records.first)
        // A third generation lands on top before recovery ever runs.
        let third = try MHLHistoryStore.append(
            report: ReportFixtures.verifiedReport(destinations: [world.destination]),
            destination: world.destination,
            fileSystem: RealFileSystem()
        )
        _ = try #require(third)

        let acted = MHLHistoryStore.rollbackUncommitted(
            generationURL: record.generationURL,
            chainURL: record.chainURL,
            archiveURL: record.archiveURL,
            fileSystem: RealFileSystem()
        )
        #expect(!acted)
        #expect(FileManager.default.fileExists(atPath: record.generationURL.path))
        #expect(try MHLReader.validateChain(at: world.directory).entries.map(\.sequence) == [1, 2, 3])
    }

    @Test func firstGenerationRollbackRemovesTheChain() async throws {
        let fixtures = try FixtureBuilder()
        let source = try fixtures.makeCard(files: EngineHarness.standardFiles)
        let destination = try fixtures.makeDestination(named: "fresh")
        let run = try await EngineHarness.run(
            fileSystem: RealFileSystem(),
            source: source,
            destinations: [destination],
            spool: fixtures.root.appendingPathComponent("spool")
        )
        #expect(run.report.status == .verified)
        let record = try #require(run.events.compactMap { event -> MHLGenerationRecord? in
            guard case .mhlGenerationWritten(let destination, let generationURL, let chainURL, let archiveURL) = event
            else { return nil }
            return MHLGenerationRecord(
                destination: destination, generationURL: generationURL, chainURL: chainURL, archiveURL: archiveURL
            )
        }.first)
        #expect(record.archiveURL == nil)

        let acted = MHLHistoryStore.rollbackUncommitted(
            generationURL: record.generationURL,
            chainURL: record.chainURL,
            archiveURL: nil,
            fileSystem: RealFileSystem()
        )
        #expect(acted)
        #expect(!FileManager.default.fileExists(atPath: record.generationURL.path))
        #expect(!FileManager.default.fileExists(atPath: record.chainURL.path))
        // Idempotent: a second pass finds nothing to do.
        #expect(!MHLHistoryStore.rollbackUncommitted(
            generationURL: record.generationURL,
            chainURL: record.chainURL,
            archiveURL: nil,
            fileSystem: RealFileSystem()
        ))
    }
}
