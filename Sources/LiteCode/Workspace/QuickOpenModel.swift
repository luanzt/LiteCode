import Foundation
import LiteCodeCore
import Observation

/// Quick Open (⌘P): fuzzy file search over the workspace, recently opened files first, as in VS Code.
@MainActor
@Observable
final class QuickOpenModel {
    struct Item: Identifiable, Equatable, Sendable {
        /// Path relative to the workspace root.
        let path: String
        /// Matched UTF-16 offsets in `path`.
        let highlights: [Int]
        let isRecent: Bool

        var id: String { path }
        var nameStart: Int { (path.utf16.lastIndex(of: 47).map { path.utf16.distance(from: path.utf16.startIndex, to: $0) } ?? -1) + 1 }
        var name: String { String(path.utf16.dropFirst(nameStart)) ?? path }
        var directory: String { nameStart > 0 ? String(path.utf16.prefix(nameStart - 1)) ?? "" : "" }
    }

    /// File results shown after the recently opened ones.
    nonisolated static let limit = 100

    private(set) var isVisible = false
    var query = "" { didSet { if query != oldValue { update() } } }
    private(set) var items: [Item] = []
    var selection = 0
    private(set) var focusRequest = 0

    @ObservationIgnored private var files: [String] = []
    @ObservationIgnored private var recents: [String] = []
    @ObservationIgnored private var rankTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedItem: Item? { items.indices.contains(selection) ? items[selection] : nil }

    /// Opens with an empty query listing `recents` (relative paths, most recent first), then
    /// loads the workspace's file list in the background.
    func show(root: URL, useGit: Bool, recents: [String]) {
        self.recents = recents
        query = ""
        isVisible = true
        focusRequest += 1
        update()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let prefix = root.path + "/"
            let paths = await SearchModel.files(in: root, useGit: useGit)
                .map(\.path)
                .filter { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)) }
            guard let self, !Task.isCancelled, self.isVisible else { return }
            self.files = paths
            self.update()
        }
    }

    func close() {
        isVisible = false
        rankTask?.cancel()
        loadTask?.cancel()
    }

    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + offset + items.count) % items.count
    }

    private func update() {
        rankTask?.cancel()
        let query = query, files = files, recents = recents
        rankTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                Self.rank(query: query, files: files, recents: recents)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.items = ranked
            self.selection = 0
        }
    }

    /// Recently opened matches first, then the best-scoring other files.
    nonisolated static func rank(query: String, files: [String], recents: [String]) -> [Item] {
        guard !query.allSatisfy(\.isWhitespace) else {
            return recents.map { Item(path: $0, highlights: [], isRecent: true) }
        }
        func matches(_ paths: some Sequence<String>, recent: Bool) -> [(item: Item, score: Int)] {
            paths.compactMap { path in
                FuzzyMatch.match(query, path: path).map { (Item(path: path, highlights: $0.indices, isRecent: recent), $0.score) }
            }
            .sorted { $0.score > $1.score }
        }
        let recentSet = Set(recents)
        let recent = matches(recents, recent: true)
        let others = matches(files.lazy.filter { !recentSet.contains($0) }, recent: false).prefix(limit)
        return recent.map(\.item) + others.map(\.item)
    }
}
