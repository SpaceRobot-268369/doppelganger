import Foundation

/// One file being offloaded, with its relative path preserved from the source
/// root. The path uses "/" separators and is the item's identity for the whole
/// transfer: progress, results, and the manifest all key on it.
public struct SourceItem: Sendable, Hashable, Identifiable {
    public let relativePath: String
    public let size: Int64
    /// Source modification time captured during enumeration. It lets the
    /// worker detect a card/folder that changed between planning and copy.
    public let modificationTime: TimeInterval?

    public var id: String { relativePath }

    public init(relativePath: String, size: Int64, modificationTime: TimeInterval? = nil) {
        self.relativePath = relativePath
        self.size = size
        self.modificationTime = modificationTime
    }
}
