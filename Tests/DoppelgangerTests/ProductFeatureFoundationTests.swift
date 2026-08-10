import Foundation
import Testing
@testable import Doppelganger

struct ProductFeatureFoundationTests {
    @Test @MainActor func settingsPackageRoundTripsWithoutHistoryOrEvidence() throws {
        let sourceSuite = "SettingsSource-\(UUID().uuidString)"
        let targetSuite = "SettingsTarget-\(UUID().uuidString)"
        let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
        let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
        defer {
            sourceDefaults.removePersistentDomain(forName: sourceSuite)
            targetDefaults.removePersistentDomain(forName: targetSuite)
        }
        sourceDefaults.set(3, forKey: AppModel.maxConcurrentKey)
        sourceDefaults.set(ChecksumAlgorithm.md5.rawValue, forKey: AppModel.checksumAlgorithmKey)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-settings-test-\(UUID().uuidString)", isDirectory: true)
        let avatarRoot = root.appendingPathComponent("avatars", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceStore = ProductStore(
            database: try ProductDatabase(inMemory: true),
            avatars: AvatarStore(root: avatarRoot),
            spoolRoot: nil
        )
        sourceStore.updateProfile(sourceStore.activeProfile, displayName: "Exported DIT")
        let sourceLibrary = WorkflowLibraryStore(defaults: sourceDefaults)
        sourceLibrary.addDestination(url: destinationRoot, role: .archive)
        sourceLibrary.addTemplate(name: "Card", pattern: "{project}_{day}_{camera}_{card}")

        let package = root.appendingPathComponent("settings.doppelgangersettings")
        try SettingsPackageService.export(
            to: package,
            store: sourceStore,
            workflowLibrary: sourceLibrary,
            defaults: sourceDefaults
        )

        let targetStore = ProductStore(
            database: try ProductDatabase(inMemory: true),
            avatars: AvatarStore(root: root.appendingPathComponent("imported-avatars")),
            spoolRoot: nil
        )
        let targetLibrary = WorkflowLibraryStore(defaults: targetDefaults)
        try SettingsPackageService.importPackage(
            from: package,
            store: targetStore,
            workflowLibrary: targetLibrary,
            defaults: targetDefaults
        )

        #expect(targetStore.activeProfile.displayName == "Exported DIT")
        #expect(targetLibrary.destinations.first?.role == .archive)
        #expect(targetLibrary.templates.contains { $0.pattern.contains("{card}") })
        #expect(targetDefaults.integer(forKey: AppModel.maxConcurrentKey) == 3)
        #expect(targetDefaults.string(forKey: AppModel.checksumAlgorithmKey) == ChecksumAlgorithm.md5.rawValue)
        #expect(targetStore.taskHistory.isEmpty)
    }

    @Test @MainActor func destinationLibraryPersistsRoleAndStableVolumeObservation() throws {
        let suite = "DestinationLibraryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doppelganger-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = WorkflowLibraryStore(defaults: defaults)
        store.addDestination(url: root, role: .archive)
        let saved = try #require(store.destinations.first)
        #expect(saved.role == .archive)
        #expect(saved.volumeIdentifier != nil)
        #expect(saved.totalBytes != nil)

        let reloaded = WorkflowLibraryStore(defaults: defaults)
        #expect(reloaded.destinations.first?.id == saved.id)
        #expect(reloaded.destinations.first?.volumeIdentifier == saved.volumeIdentifier)
    }

    @Test func namingTemplateUsesOnlyKnownTokensAndSanitizesOutput() {
        #expect(NamingTemplateRenderer.validate("{date}_{project}_{day}_{camera}_{card}_{source}_{counter}"))
        #expect(!NamingTemplateRenderer.validate("{unknown}_{source}"))
        let rendered = NamingTemplateRenderer.render(
            "{date}_{project}_{day}_{camera}_{card}_{source}_{operator}_{counter}",
            date: Date(timeIntervalSince1970: 1_754_700_000),
            project: "Feature/One",
            source: "card-a",
            shootingDay: "Day 03",
            camera: "A Camera",
            card: "C007",
            operatorName: "Alex:DIT",
            counter: 7
        )
        #expect(rendered.contains("FEATURE") == false)
        #expect(!rendered.contains("/"))
        #expect(!rendered.contains(":"))
        #expect(rendered.hasSuffix("007"))
        #expect(rendered.contains("Day 03"))
        #expect(rendered.contains("A Camera"))
        #expect(rendered.contains("C007"))
    }

    @Test func sourcePlanFingerprintIsStableAndSensitiveToPlanChanges() {
        let items = [
            SourceItem(relativePath: "A.mov", size: 10, modificationTime: 1),
            SourceItem(relativePath: "B.mov", size: 20, modificationTime: 2),
        ]
        #expect(TransferPreflight.planFingerprint(items)
            == TransferPreflight.planFingerprint(Array(items.reversed())))
        var changed = items
        changed[1] = SourceItem(relativePath: "B.mov", size: 21, modificationTime: 2)
        #expect(TransferPreflight.planFingerprint(items)
            != TransferPreflight.planFingerprint(changed))
    }

    @Test func sourceHistoryDistinguishesUnchangedChangedAndSimilarMedia() {
        let task = TaskHistoryRecord(
            id: UUID(),
            label: "Card",
            sourcePath: "/synthetic/card",
            sourceFingerprint: "plan-a",
            sourceVolumeIdentifier: "volume-a",
            sourceVolumeName: "CARD_A",
            destinationPaths: [],
            projectID: nil,
            projectName: nil,
            operatorSnapshot: OperatorSnapshot(profileID: UUID(), displayName: "DIT"),
            algorithm: .xxh3,
            verificationProfile: .standard,
            lifecycle: .complete,
            verdict: .verified,
            createdAt: Date(),
            updatedAt: Date()
        )
        #expect(task.relationship(toFingerprint: "plan-a", volumeIdentifier: "other", volumeName: "OTHER") == .unchanged)
        #expect(task.relationship(toFingerprint: "plan-b", volumeIdentifier: "volume-a", volumeName: "OTHER") == .changed)
        #expect(task.relationship(toFingerprint: "plan-b", volumeIdentifier: "other", volumeName: "card_a") == .similar)
        #expect(task.relationship(toFingerprint: "plan-b", volumeIdentifier: "other", volumeName: "OTHER") == .unrelated)
    }

    @Test func destinationBenchmarkUsesAndRemovesOnlyItsTemporaryFile() async throws {
        let fixtures = try FixtureBuilder()
        let destination = try fixtures.makeDestination(named: "benchmark")
        let result = try await DestinationBenchmarkService.run(
            at: destination,
            byteCount: 1024 * 1024
        )
        #expect(result.testedBytes == 1024 * 1024)
        #expect(result.writeBytesPerSecond > 0)
        #expect(result.readBytesPerSecond > 0)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        #expect(remaining.isEmpty)
    }

    @Test func mediaAnalyzerRecognizesCameraAndAudioLayouts() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("PRIVATE/M4ROOT/CLIP/C0001.MXF", size: 10, seed: 1),
            .init("AUDIO/TAKE001.WAV", size: 10, seed: 2),
        ])
        let items = try RealFileSystem().enumerate(root: card)
        let analysis = await MediaAnalyzer.analyze(root: card, items: items)
        #expect(analysis.detectedFormats.contains("Sony"))
        #expect(analysis.detectedFormats.contains("Production Audio"))
        #expect(analysis.mediaFileCount == 2)
        #expect(!analysis.findings.contains { $0.severity == .error })
    }

    @Test func mediaHealthFindsSequenceGapsAndOrphanSidecars() async throws {
        let fixtures = try FixtureBuilder()
        let card = try fixtures.makeCard(files: [
            .init("ARRI/A001_0001.ari", size: 10, seed: 1),
            .init("ARRI/A001_0003.ari", size: 10, seed: 2),
            .init("ARRI/ORPHAN.xml", size: 10, seed: 3),
        ])
        let analysis = await MediaAnalyzer.analyze(
            root: card,
            items: try RealFileSystem().enumerate(root: card)
        )
        #expect(analysis.detectedFormats.contains("ARRI"))
        #expect(analysis.findings.contains { $0.code == "sequence-gap" })
        #expect(analysis.findings.contains { $0.code == "orphan-sidecar" })
    }
}
