/// One file being offloaded, with its relative path preserved from the source
/// root. The path uses "/" separators and is the item's identity for the whole
/// transfer: progress, results, and the manifest all key on it.
public struct SourceItem: Sendable, Hashable, Identifiable {
    public let relativePath: String
    public let size: Int64

    public var id: String { relativePath }

    public init(relativePath: String, size: Int64) {
        self.relativePath = relativePath
        self.size = size
    }
}
