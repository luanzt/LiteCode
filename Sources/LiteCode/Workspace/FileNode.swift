import Foundation
import Observation

/// Lazily loaded file-tree node: a directory lists its children only once expanded.
@MainActor
@Observable
final class FileNode: Identifiable {
    let url: URL
    let isDirectory: Bool
    var isExpanded = false
    private(set) var children: [FileNode]?

    nonisolated var id: URL { url }
    var name: String { url.lastPathComponent }
    var path: String { url.path }

    private static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Re-lists the directory, keeping existing child nodes so their expansion survives.
    func reloadChildren() {
        guard isDirectory else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let existing = Dictionary((children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        children = entries
            .filter { !Self.hiddenNames.contains($0.lastPathComponent) }
            .map { entry in
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if let node = existing[entry.lastPathComponent], node.isDirectory == isDirectory { return node }
                // Derive from our own URL so every path in the tree shares the canonical root prefix.
                return FileNode(url: url.appendingPathComponent(entry.lastPathComponent, isDirectory: isDirectory), isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func toggle() {
        isExpanded.toggle()
        if isExpanded { reloadChildren() }
    }

    /// Expanded directories in this subtree, including self.
    func expandedDirectories() -> [FileNode] {
        guard isDirectory, isExpanded else { return [] }
        return [self] + (children ?? []).flatMap { $0.expandedDirectories() }
    }

    /// Expands every folder between this node and `path`, loading listings as needed, and
    /// returns the node for `path`; nil when it lies outside this subtree or no longer exists.
    func reveal(path: String) -> FileNode? {
        guard path.hasPrefix(self.path + "/") else { return nil }
        var node = self
        for name in path.dropFirst(self.path.count + 1).split(separator: "/") {
            if node.children == nil { node.reloadChildren() }
            // A file created since the last listing isn't in it yet.
            if node.children?.contains(where: { $0.name == name }) != true { node.reloadChildren() }
            guard let child = node.children?.first(where: { $0.name == name }) else { return nil }
            if !node.isExpanded { node.isExpanded = true }
            node = child
        }
        return node
    }

    /// Rows currently visible in the tree, depth-first.
    func visibleRows(depth: Int = 0) -> [(node: FileNode, depth: Int)] {
        guard isExpanded, let children else { return [] }
        return children.flatMap { child in [(child, depth)] + child.visibleRows(depth: depth + 1) }
    }
}
