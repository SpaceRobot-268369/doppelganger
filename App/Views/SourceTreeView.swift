import SwiftUI

/// One node of the reviewed source plan's folder structure.
struct SourceTreeNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let byteCount: Int64
    let fileCount: Int
    /// `nil` for files, so `OutlineGroup` renders them without a chevron.
    let children: [SourceTreeNode]?

    /// Folds enumerated items into a directory tree. The paths come from the
    /// preflight scan, so building this reads nothing from disk.
    ///
    /// - Parameter childLimit: how many entries a single directory renders
    ///   before collapsing the rest into one summary row. A card with tens of
    ///   thousands of files must not stall the review sheet.
    static func build(from items: [SourceItem], childLimit: Int = 200) -> [SourceTreeNode] {
        final class Builder {
            var directories: [String: Builder] = [:]
            var files: [(name: String, size: Int64)] = []
        }

        let root = Builder()
        for item in items {
            var components = item.relativePath.split(separator: "/").map(String.init)
            guard let fileName = components.popLast() else { continue }
            var cursor = root
            for component in components {
                if let existing = cursor.directories[component] {
                    cursor = existing
                } else {
                    let child = Builder()
                    cursor.directories[component] = child
                    cursor = child
                }
            }
            cursor.files.append((fileName, item.size))
        }

        func materialize(_ builder: Builder, path: String) -> [SourceTreeNode] {
            var nodes = builder.directories
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { name, child -> SourceTreeNode in
                    let childPath = path.isEmpty ? name : "\(path)/\(name)"
                    let grandchildren = materialize(child, path: childPath)
                    return SourceTreeNode(
                        id: childPath,
                        name: name,
                        isDirectory: true,
                        byteCount: grandchildren.reduce(0) { $0 + $1.byteCount },
                        fileCount: grandchildren.reduce(0) { $0 + $1.fileCount },
                        children: grandchildren
                    )
                }
            nodes += builder.files
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { file in
                    SourceTreeNode(
                        id: path.isEmpty ? file.name : "\(path)/\(file.name)",
                        name: file.name,
                        isDirectory: false,
                        byteCount: file.size,
                        fileCount: 1,
                        children: nil
                    )
                }
            guard nodes.count > childLimit else { return nodes }
            let hidden = nodes[childLimit...]
            return Array(nodes.prefix(childLimit)) + [
                SourceTreeNode(
                    id: "\(path)/…",
                    name: L10n.format("…and %lld more", Int64(hidden.count)),
                    isDirectory: false,
                    byteCount: hidden.reduce(0) { $0 + $1.byteCount },
                    fileCount: hidden.reduce(0) { $0 + $1.fileCount },
                    children: nil
                )
            ]
        }

        return materialize(root, path: "")
    }
}

/// The scanned source's folder structure, so the operator can confirm the plan
/// covers what they expect before any destination is touched.
struct SourceTreeView: View {
    let nodes: [SourceTreeNode]

    var body: some View {
        if nodes.isEmpty {
            Text("The scan found no files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(nodes) { node in
                        OutlineGroup(node, children: \.children) { entry in
                            row(entry)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row(_ node: SourceTreeNode) -> some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder" : "doc")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(node.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if node.isDirectory {
                Text("\(node.fileCount) files")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text(Format.bytes(node.byteCount))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}
