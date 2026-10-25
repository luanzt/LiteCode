import Foundation
import LiteCodeCore
import Observation

/// Project-wide text search for the sidebar (⇧⌘F), run off the main thread as the query changes.
@MainActor
@Observable
final class SearchModel {
    struct FileResult: Identifiable, Sendable {
        var url: URL
        var relativePath: String
        var matches: [LineMatch]
        var id: String { url.path }
        var matchCount: Int { matches.reduce(0) { $0 + $1.ranges.count } }
    }

    /// Stop collecting after this many matches; the UI says the list is truncated.
    nonisolated static let matchLimit = 5000
    nonisolated private static let maxFileSize = 2_000_000
    nonisolated private static let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "build", "dist", "Pods", "DerivedData", ".next", ".expo"]

    var query = ""
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var collapsed: Set<String> = []

    private(set) var results: [FileResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var truncated = false

    @ObservationIgnored private var task: Task<Void, Never>?

    var totalMatches: Int { results.reduce(0) { $0 + $1.matchCount } }

    /// Restarts the search after a short pause in typing; `repositoryRoot` enables git's file list
    /// (respects .gitignore), otherwise the folder is walked directly.
    func schedule(root: URL, repositoryRoot: URL?) {
        task?.cancel()
        let options = SearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
        guard !query.isEmpty else {
            results = []
            errorMessage = nil
            truncated = false
            isSearching = false
            return
        }
        let expression: NSRegularExpression
        do {
            expression = try options.expression()
        } catch {
            errorMessage = "Invalid regular expression"
            results = []
            isSearching = false
            return
        }
        errorMessage = nil
        isSearching = true
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let files = await Self.files(in: root, useGit: repositoryRoot != nil)
            let (found, hitLimit) = await Task.detached(priority: .userInitiated) {
                Self.search(files: files, root: root, expression: expression)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.results = found
            self.truncated = hitLimit
            self.isSearching = false
        }
    }

    /// Files to search or offer in Quick Open: git's list (honoring .gitignore) or a filtered walk.
    static func files(in root: URL, useGit: Bool) async -> [URL] {
        if useGit, let paths = await Git.listFiles(in: root) {
            return paths.map { root.appendingPathComponent($0) }
        }
        return await Task.detached(priority: .userInitiated) { walk(root) }.value
    }

    nonisolated private static func walk(_ root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            } else if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    nonisolated private static func search(files: [URL], root: URL, expression: NSRegularExpression) -> ([FileResult], Bool) {
        var results: [FileResult] = []
        var remaining = matchLimit
        let prefix = root.path + "/"
        for url in files {
            if Task.isCancelled || remaining <= 0 { break }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileSize,
                  let data = try? Data(contentsOf: url), !data.prefix(8000).contains(0)
            else { continue }
            let matches = TextSearch.matches(of: expression, in: String(decoding: data, as: UTF8.self), limit: remaining)
            guard !matches.isEmpty else { continue }
            let relative = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            let result = FileResult(url: url, relativePath: relative, matches: matches)
            remaining -= result.matchCount
            results.append(result)
        }
        return (results.sorted { TextSearch.precedes($0.relativePath, $1.relativePath) }, remaining <= 0)
    }
}
