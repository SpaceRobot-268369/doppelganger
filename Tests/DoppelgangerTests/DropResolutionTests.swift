import AppKit
import Foundation
import Testing
@testable import Doppelganger

/// Finder drops reach New Offload as `NSItemProvider`s. The main-actor drop
/// handler awaits each provider's file URL, which `loadObject` delivers through
/// a callback; the round trip must hand that URL back unchanged.
@MainActor
struct DropResolutionTests {
    @Test func droppedFolderResolvesToItsFileURL() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropResolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = NSItemProvider(object: folder as NSURL)
        let resolved = await provider.resolvedFileURL()

        #expect(resolved?.standardizedFileURL == folder.standardizedFileURL)
    }
}
