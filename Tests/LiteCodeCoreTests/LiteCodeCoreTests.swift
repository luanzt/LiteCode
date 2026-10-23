import Foundation
import LiteCodeCore
import Testing

@Suite struct LineDiffTests {
    @Test func pairsReplacedLinesAndKeepsUnchangedOnesAligned() {
        let rows = LineDiff.rows(original: ["a", "b", "c", "d"], modified: ["a", "B", "c", "d", "e"])
        #expect(rows == [
            DiffRow(kind: .same, left: 0, right: 0),
            DiffRow(kind: .changed, left: 1, right: 1),
            DiffRow(kind: .same, left: 2, right: 2),
            DiffRow(kind: .same, left: 3, right: 3),
            DiffRow(kind: .added, left: nil, right: 4),
        ])
    }

    @Test func unevenReplacementLeavesFillerOnTheShorterSide() {
        let rows = LineDiff.rows(original: ["x", "old1", "old2", "y"], modified: ["x", "new", "y"])
        #expect(rows == [
            DiffRow(kind: .same, left: 0, right: 0),
            DiffRow(kind: .changed, left: 1, right: 1),
            DiffRow(kind: .removed, left: 2, right: nil),
            DiffRow(kind: .same, left: 3, right: 2),
        ])
    }

    @Test func newAndDeletedFilesAreOneSided() {
        #expect(LineDiff.rows(original: [], modified: ["a", "b"]).allSatisfy { $0.kind == .added && $0.left == nil })
        #expect(LineDiff.rows(original: ["a", "b"], modified: []).allSatisfy { $0.kind == .removed && $0.right == nil })
    }

    @Test func hunksCoverEachSideIncludingInsertionPoints() {
        let original = ["a", "b", "c", "d", "e"]
        let modified = ["A", "b", "d", "e", "f"]
        let hunks = LineDiff.hunks(LineDiff.rows(original: original, modified: modified))
        #expect(hunks == [
            LineDiff.Hunk(rows: 0..<1, original: 0..<1, modified: 0..<1),
            // "c" deleted: nothing on the modified side, inserted before "d" (index 2).
            LineDiff.Hunk(rows: 2..<3, original: 2..<3, modified: 2..<2),
            LineDiff.Hunk(rows: 5..<6, original: 5..<5, modified: 4..<5),
        ])
        // Applying a hunk's modified side to the original stages just that change.
        let staged = LineDiff.replacing(hunks[1].original, in: original, with: modified[hunks[1].modified])
        #expect(staged == ["a", "b", "d", "e"])
    }

    @Test func changedSpanIsolatesTheEditedMiddle() {
        let span = LineDiff.changedSpan("  params?: Record", "  params?d: Record")
        #expect(span?.old == 9..<9)
        #expect(span?.new == 9..<10)
        // Repeated characters at the edit point must not let prefix and suffix overlap.
        let repeated = LineDiff.changedSpan("aa", "aaa")
        #expect(repeated?.old == 2..<2)
        #expect(repeated?.new == 2..<3)
        #expect(LineDiff.changedSpan("abc", "xyz") == nil)
    }
}

@Suite struct GitStatusParserTests {
    @Test func classifiesPorcelainEntries() {
        let output = " M src/app.swift\0?? new file.txt\0D  gone.md\0A  added.c\0UU both.txt\0!! ignored.log\0"
        let changes = GitStatusParser.parse(output)
        #expect(changes == [
            GitChange(path: "added.c", status: .added, stage: .staged),
            GitChange(path: "both.txt", status: .conflicted),
            GitChange(path: "gone.md", status: .deleted, stage: .staged),
            GitChange(path: "new file.txt", status: .untracked),
            GitChange(path: "src/app.swift", status: .modified),
        ])
    }

    @Test func partlyStagedFileAppearsInBothGroups() {
        let changes = GitStatusParser.parse("MM both.swift\0AD gone.swift\0")
        #expect(changes == [
            GitChange(path: "both.swift", status: .modified, stage: .staged),
            GitChange(path: "both.swift", status: .modified),
            GitChange(path: "gone.swift", status: .added, stage: .staged),
            GitChange(path: "gone.swift", status: .deleted),
        ])
    }

    @Test func renameConsumesTheSourcePathField() {
        let changes = GitStatusParser.parse("RM new.swift\0old.swift\0 M other.swift\0")
        #expect(changes == [
            GitChange(path: "new.swift", originalPath: "old.swift", status: .renamed, stage: .staged),
            GitChange(path: "new.swift", status: .modified),
            GitChange(path: "other.swift", status: .modified),
        ])
    }
}

@Suite struct IconThemeManifestTests {
    private let manifest = try! IconThemeManifest(data: Data("""
        {
          "iconDefinitions": { "react_ts": { "iconPath": "./../icons/react_ts.svg" } },
          "fileNames": { ".env.development": "tune", "package.json": "nodejs", "README.md": "readme" },
          "fileExtensions": { "tsx": "react_ts", "test.tsx": "test-jsx", "env": "tune", "js": "javascript" },
          "folderNames": { "utils": "folder-utils", ".github/workflows": "folder-gh-workflows" },
          "folderNamesExpanded": { "utils": "folder-utils-open" },
          "file": "file", "folder": "folder", "folderExpanded": "folder-open"
        }
        """.utf8))

    @Test func fileNameBeatsExtensionAndMatchesCaseInsensitively() {
        #expect(manifest.fileIcon(for: ".env.development") == "tune")
        #expect(manifest.fileIcon(for: "Package.JSON") == "nodejs")
        #expect(manifest.fileIcon(for: "readme.md") == "readme")
    }

    @Test func longestCompoundExtensionWins() {
        #expect(manifest.fileIcon(for: "Signin.test.tsx") == "test-jsx")
        #expect(manifest.fileIcon(for: "SigninView.tsx") == "react_ts")
        #expect(manifest.fileIcon(for: ".detoxrc.js") == "javascript")
        #expect(manifest.fileIcon(for: ".env") == "tune")
        #expect(manifest.fileIcon(for: "Makefile") == "file")
    }

    @Test func foldersUseExpandedVariantsAndIgnorePathKeys() {
        #expect(manifest.folderIcon(for: "Utils", expanded: false) == "folder-utils")
        #expect(manifest.folderIcon(for: "utils", expanded: true) == "folder-utils-open")
        #expect(manifest.folderIcon(for: "workflows", expanded: false) == "folder")
        #expect(manifest.folderIcon(for: "other", expanded: true) == "folder-open")
        #expect(manifest.svgFileName(for: "react_ts") == "react_ts.svg")
    }
}

@Suite struct TextSearchTests {
    private let text = "let Value = 1\nvalue += valueOf(x)\n\nprint(value)"

    private func search(_ options: SearchOptions) throws -> [LineMatch] {
        TextSearch.matches(of: try options.expression(), in: text)
    }

    @Test func groupsCaseInsensitiveMatchesByLine() throws {
        let results = try search(SearchOptions(query: "value"))
        #expect(results.map(\.line) == [0, 1, 3])
        #expect(results[1].text == "value += valueOf(x)")
        #expect(results[1].ranges == [NSRange(location: 0, length: 5), NSRange(location: 9, length: 5)])
    }

    @Test func caseSensitiveAndWholeWordNarrowMatches() throws {
        #expect(try search(SearchOptions(query: "Value", caseSensitive: true)).map(\.line) == [0])
        let whole = try search(SearchOptions(query: "value", wholeWord: true))
        #expect(whole[1].ranges == [NSRange(location: 0, length: 5)])
    }

    @Test func regexIsOptInAndInvalidPatternsThrow() throws {
        #expect(try search(SearchOptions(query: "value\\w+", regex: true)).map(\.line) == [1])
        #expect(try search(SearchOptions(query: "value\\w+")).isEmpty)
        #expect(throws: (any Error).self) { try SearchOptions(query: "(", regex: true).expression() }
    }

    @Test func stopsAtLimit() throws {
        let results = TextSearch.matches(of: try SearchOptions(query: "value").expression(), in: text, limit: 2)
        #expect(results.flatMap(\.ranges).count == 2)
    }
}

@Suite struct GutterMarksTests {
    @Test func marksAddedModifiedAndDeletedLines() {
        let base = ["a", "b", "c", "d", "e"]
        let current = ["a", "B", "c", "new", "e"]
        // d removed and "new" added in its place pairs into a modification.
        #expect(GutterMarks.compute(base: base, current: current)
            == GutterMarks(modified: [1, 3]))
        #expect(GutterMarks.compute(base: ["a", "b"], current: ["a", "b", "c"])
            == GutterMarks(added: [2]))
        #expect(GutterMarks.compute(base: ["a", "b", "c"], current: ["a", "c"])
            == GutterMarks(deletedBefore: [1]))
        #expect(GutterMarks.compute(base: ["a", "b"], current: ["a"])
            == GutterMarks(deletedBefore: [1]))
        #expect(GutterMarks.compute(base: ["a"], current: ["a"]).isEmpty)
    }
}

@Suite struct FuzzyMatchTests {
    private func ranked(_ query: String, _ paths: [String]) -> [String] {
        paths.compactMap { path in FuzzyMatch.match(query, path: path).map { (path, $0.score) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    @Test func prefersFileNameWordStartsOverScatteredPathMatches() {
        let paths = ["src/recommendations/list.ts", "reducers/common.ts", "constants/commonly-used.ts"]
        #expect(ranked("comm", paths) == ["reducers/common.ts", "constants/commonly-used.ts", "src/recommendations/list.ts"])
    }

    @Test func matchesAcrossWordBoundariesAndHighlightsThem() {
        let match = FuzzyMatch.match("emset", path: "reducers/email-settings.ts")
        // "em" at the name start, then "set" at the start of "settings".
        #expect(match?.indices == [9, 10, 15, 16, 17])
        #expect(FuzzyMatch.match("sv", path: "screens/SigninView.tsx")?.indices == [8, 14])
    }

    @Test func slashQueriesMatchThePathAndNonMatchesAreRejected() {
        #expect(ranked("red/com", ["utils/common.ts", "reducers/common.ts"]) == ["reducers/common.ts"])
        #expect(FuzzyMatch.match("xyz", path: "reducers/common.ts") == nil)
        #expect(FuzzyMatch.match("COMMON", path: "reducers/common.ts") != nil)
    }
}
