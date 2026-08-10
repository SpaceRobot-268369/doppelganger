import Foundation

struct DemoWorkspace: Sendable {
    let source: URL
    let destinations: [URL]
}

enum DemoWorkspaceService {
    /// Creates a new app-owned synthetic camera card and two empty destination
    /// roots. It never scans, copies, or deletes user media.
    static func prepare() throws -> DemoWorkspace {
        let manager = FileManager.default
        let applicationSupport = manager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? manager.temporaryDirectory
        let root = applicationSupport
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.lucastao.doppelganger", isDirectory: true)
            .appendingPathComponent("Demo Workspaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let source = root.appendingPathComponent("SYNTHETIC_CARD", isDirectory: true)
        let clipFolder = source.appendingPathComponent("DCIM/100DEMO", isDirectory: true)
        let destinationA = root.appendingPathComponent("DESTINATION_A", isDirectory: true)
        let destinationB = root.appendingPathComponent("DESTINATION_B", isDirectory: true)
        try manager.createDirectory(at: clipFolder, withIntermediateDirectories: true)
        try manager.createDirectory(at: destinationA, withIntermediateDirectories: true)
        try manager.createDirectory(at: destinationB, withIntermediateDirectories: true)

        let readme = """
        Doppelganger synthetic demo card
        These files were generated locally for the guided demo. They are not user media.
        """
        try Data(readme.utf8).write(
            to: source.appendingPathComponent("README.txt"),
            options: .withoutOverwriting
        )

        for index in 1...3 {
            let header = "DOPPELGANGER-DEMO-CLIP-\(index)\n"
            var bytes = Data(header.utf8)
            bytes.append(Data(repeating: UInt8(index * 37), count: index * 96 * 1024))
            try bytes.write(
                to: clipFolder.appendingPathComponent(String(format: "DEMO_%03d.bin", index)),
                options: .withoutOverwriting
            )
        }
        return DemoWorkspace(source: source, destinations: [destinationA, destinationB])
    }
}
