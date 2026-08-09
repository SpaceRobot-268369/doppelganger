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
}
