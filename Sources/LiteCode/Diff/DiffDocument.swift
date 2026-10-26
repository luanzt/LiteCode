import AppKit
import LiteCodeCore
import Observation

/// Side-by-side comparison of a changed file, as in VS Code: a staged change compares HEAD
/// with the index ("(Index)"), an unstaged one the index with the working tree ("(Working
/// Tree)"). Both whole files are shown with changes tinted in place, so the surrounding code
/// stays readable; rows the other side lacks become hatched gaps, and the panes scroll
/// together. The working-tree side is the file itself, editable and shared with its editor tab.
@MainActor
@Observable
final class DiffDocument {
    enum HunkAction { case revert, stage, unstage }

    private(set) var change: GitChange
    let repositoryRoot: URL
    private(set) var addedCount = 0
    private(set) var removedCount = 0
    private(set) var isBinary = false
    private(set) var isLoaded = false
    /// The working-tree file when this diff edits it (unstaged and not deleted); the same
    /// document an editor tab for the file uses.
    let editable: EditorDocument?
    let find = FindModel()

    @ObservationIgnored private let writeIndex: (Data, String) -> Void
    @ObservationIgnored private var loadGeneration = 0
    /// Bumped on every edit of `editable`, so results computed from older text are dropped.
    @ObservationIgnored private var editCount = 0
    @ObservationIgnored private(set) var layout: DiffLayout?
    @ObservationIgnored private var pendingFirstChange = true
    /// Last hunk jumped to and where that left the view; while the view hasn't moved, stepping
    /// continues from it (near the end of the file the scroll clamps, so the top can't tell).
    @ObservationIgnored private var lastReveal: (hunk: Int, origin: NSPoint)?
    @ObservationIgnored private var isSyncingScroll = false
    @ObservationIgnored private var recomputeWork: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var _views: DiffViews?

    /// `writeIndex(content, path)` stages new index content for one file (hunk staging).
    init(change: GitChange, repositoryRoot: URL, editable: EditorDocument?, writeIndex: @escaping (Data, String) -> Void) {
        self.change = change
        self.repositoryRoot = repositoryRoot
        self.editable = editable.flatMap { $0.isBinary ? nil : $0 }
        self.writeIndex = writeIndex
    }

    var name: String { (change.path as NSString).lastPathComponent }
    var fileURL: URL { repositoryRoot.appendingPathComponent(change.path) }
    var hunkCount: Int { layout?.hunks.count ?? 0 }
    var isDirty: Bool { editable?.isDirty ?? false }

    /// Created on first display; kept for the tab's lifetime so scroll positions survive tab switches.
    var views: DiffViews {
        if let _views { return _views }
        let views = DiffViews(left: DiffPane(), right: DiffPane(sharing: editable))
        _views = views
        views.gutter.document = self
        views.overview.document = self
        find.textView = views.right.textView
        views.right.textView.onCancel = { [weak self] in
            guard let self, self.find.isVisible else { return false }
            self.find.close()
            return true
        }
        for (source, target) in [(views.left, views.right), (views.right, views.left)] {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: source.scrollView.contentView, queue: nil
            ) { [weak self, weak source, weak target] _ in
                MainActor.assumeIsolated {
                    guard let self, let source, let target else { return }
                    self.syncScroll(from: source, to: target)
                }
            })
        }
        if let editable {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: editable.textStorage, queue: nil
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let storage = notification.object as? NSTextStorage,
                          storage.editedMask.contains(.editedCharacters) else { return }
                    self.textDidChange()
                }
            })
        }
        return views
    }

    func update(change: GitChange) {
        self.change = change
    }

    /// Tab closed: unhook from the shared document, whose storage would otherwise keep laying
    /// out this diff's pane on every edit.
    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        recomputeWork?.cancel()
        _views?.right.detach()
    }

    func reload() async {
        loadGeneration += 1
        let generation = loadGeneration
        let edits = editCount
        let change = change
        let root = repositoryRoot
        let original: Data
        var modified = Data()
        switch change.stage {
        case .staged:
            original = await Git.headContents(of: change.originalPath ?? change.path, in: root) ?? Data()
            if change.status != .deleted { modified = await Git.indexContents(of: change.path, in: root) ?? Data() }
        case .unstaged:
            if change.status == .untracked {
                original = Data()
            } else if let staged = await Git.indexContents(of: change.path, in: root) {
                original = staged
            } else {
                // Conflicted files have no stage-0 index entry; compare with HEAD instead.
                original = await Git.headContents(of: change.path, in: root) ?? Data()
            }
            if editable == nil, change.status != .deleted {
                modified = (try? Data(contentsOf: root.appendingPathComponent(change.path))) ?? Data()
            }
        }
        // The editable side is the live buffer, unsaved edits included.
        let modifiedText = editable.map { $0.textStorage.string } ?? String(decoding: modified, as: UTF8.self)
        let binary = original.prefix(8000).contains(0) || (editable == nil && modified.prefix(8000).contains(0))
        let language = Language.detect(fileURL)
        let highlightModified = editable == nil
        let result = await Task.detached(priority: .userInitiated) { () -> DiffLayout? in
            guard !binary else { return nil }
            return DiffLayout(original: String(decoding: original, as: UTF8.self), modified: modifiedText,
                              language: language, highlightModified: highlightModified)
        }.value
        guard generation == loadGeneration, edits == editCount else { return }

        isBinary = binary
        if let result { apply(result) }
        isLoaded = true
    }

    private func apply(_ result: DiffLayout) {
        let views = views
        views.left.show(text: result.originalText, runs: result.originalRuns)
        if editable == nil { views.right.show(text: result.modifiedText, runs: result.modifiedRuns) }
        views.left.decorate(styles: result.originalStyles, gaps: result.originalGaps)
        views.right.decorate(styles: result.modifiedStyles, gaps: result.modifiedGaps)
        layout = result
        layout?.editCount = editCount
        addedCount = result.addedCount
        removedCount = result.removedCount
        lastReveal = nil
        views.gutter.needsDisplay = true
        views.overview.needsDisplay = true
    }

    private func textDidChange() {
        editCount += 1
        _views?.right.textView.invalidateLineStarts()
        find.textDidChange()
        recomputeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.reload() }
        }
        recomputeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func applyFont() {
        _views?.left.applyFont()
        _views?.right.applyFont()
        _views?.gutter.needsDisplay = true
    }

    // MARK: Hunk actions

    /// The block actions VS Code offers in the gutter between the panes.
    var hunkActions: [HunkAction] {
        switch change.stage {
        case .staged: [.unstage]
        case .unstaged: editable != nil ? [.revert, .stage] : [.stage]
        }
    }

    func perform(_ action: HunkAction, on index: Int) {
        // Ranges are only valid for the text they were computed from.
        guard let layout, index < layout.hunks.count, layout.editCount == editCount || editable == nil else { return }
        let hunk = layout.hunks[index]
        switch action {
        case .revert:
            revert(hunk, layout)
        case .stage:
            let lines = LineDiff.replacing(hunk.original, in: layout.original, with: layout.modified[hunk.modified])
            let touchesEnd = hunk.original.upperBound == layout.original.count || hunk.modified.upperBound == layout.modified.count
            let newline = touchesEnd ? layout.modifiedEndsWithNewline : layout.originalEndsWithNewline
            writeIndex(Self.content(lines, newline: newline, separator: layout.originalSeparator), change.path)
        case .unstage:
            let lines = LineDiff.replacing(hunk.modified, in: layout.modified, with: layout.original[hunk.original])
            let touchesEnd = hunk.original.upperBound == layout.original.count || hunk.modified.upperBound == layout.modified.count
            let newline = touchesEnd ? layout.originalEndsWithNewline : layout.modifiedEndsWithNewline
            writeIndex(Self.content(lines, newline: newline, separator: layout.modifiedSeparator), change.path)
        }
    }

    /// Puts the original lines back into the working-tree buffer as one undoable edit.
    private func revert(_ hunk: LineDiff.Hunk, _ layout: DiffLayout) {
        let textView = views.right.textView
        let text = textView.characters
        let starts = textView.lineStarts
        let count = layout.modified.count
        let start = hunk.modified.lowerBound < count ? starts[hunk.modified.lowerBound] : text.length
        let end = hunk.modified.upperBound < count ? starts[hunk.modified.upperBound] : text.length
        var replacement = layout.original[hunk.original].map { $0 + layout.modifiedSeparator }.joined()
        let endsWithNewline = text.length == 0 || text.character(at: text.length - 1) == 10
        if end == text.length, !endsWithNewline, !replacement.isEmpty {
            // The last line has no newline: keep it that way, joining onto the previous line
            // when inserting after it.
            replacement.removeLast(layout.modifiedSeparator.count)
            if hunk.modified.isEmpty { replacement = layout.modifiedSeparator + replacement }
        }
        let range = NSRange(location: start, length: end - start)
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
    }

    private static func content(_ lines: [String], newline: Bool, separator: String) -> Data {
        var text = lines.joined(separator: separator)
        if newline && !lines.isEmpty { text += separator }
        return Data(text.utf8)
    }

    // MARK: Navigation

    /// Top of hunk `index` in the panes' shared vertical coordinates (right pane document space).
    func hunkTop(_ index: Int) -> CGFloat? {
        guard let hunk = layout?.hunks[safe: index] else { return nil }
        return views.right.top(ofLine: hunk.modified.lowerBound, gapFirst: true)
    }

    /// Called once the panes are on screen: the first load opens at the first change, as VS Code
    /// does. Both panes are laid out and sized first: the scroll is mirrored onto the left pane,
    /// whose freshly loaded text still had a short frame, and its clamped position came back.
    func revealFirstChangeIfNeeded() {
        guard pendingFirstChange, isLoaded, hunkCount > 0, views.right.scrollView.window != nil else { return }
        for pane in [views.left, views.right] {
            if let layout = pane.textView.layoutManager, let container = pane.textView.textContainer {
                layout.ensureLayout(for: container)
            }
            pane.textView.sizeToFit()
        }
        guard let top = hunkTop(0) else { return }
        pendingFirstChange = false
        views.right.scroll(toY: top)
    }

    /// Jumps to the next (`1`) or previous (`-1`) change relative to the top of the view,
    /// wrapping around like VS Code.
    func revealChange(_ direction: Int) {
        guard hunkCount > 0 else { return }
        let pane = views.right
        let origin = pane.scrollView.contentView.bounds.origin
        let index: Int
        if let lastReveal, lastReveal.origin == origin, lastReveal.hunk < hunkCount {
            index = (lastReveal.hunk + direction + hunkCount) % hunkCount
        } else {
            let anchor = pane.revealAnchor()
            let tops = (0..<hunkCount).compactMap(hunkTop)
            index = direction > 0
                ? tops.firstIndex { $0 > anchor + 1 } ?? 0
                : tops.lastIndex { $0 < anchor - 1 } ?? hunkCount - 1
        }
        guard let top = hunkTop(index) else { return }
        pane.scroll(toY: top)
        lastReveal = (index, pane.scrollView.contentView.bounds.origin)
    }

    private func syncScroll(from source: DiffPane, to target: DiffPane) {
        source.scrollView.verticalRulerView?.needsDisplay = true
        _views?.gutter.needsDisplay = true
        guard !isSyncingScroll else { return }
        isSyncingScroll = true
        let clip = target.scrollView.contentView
        clip.scroll(to: source.scrollView.contentView.bounds.origin)
        target.scrollView.reflectScrolledClipView(clip)
        target.scrollView.verticalRulerView?.needsDisplay = true
        isSyncingScroll = false
    }
}

/// The diff tab's AppKit views, owned by the document so they outlive tab switches.
@MainActor
final class DiffViews {
    let left: DiffPane
    let right: DiffPane
    let gutter = DiffActionGutter()
    let overview = DiffOverviewRuler()

    init(left: DiffPane, right: DiffPane) {
        self.left = left
        self.right = right
    }
}

/// Both sides of a diff as real file text plus decorations: per-line change styles and the
/// filler rows each side shows where the other has lines it lacks.
struct DiffLayout: Sendable {
    var original: [String]
    var modified: [String]
    var originalText: String
    var modifiedText: String
    var originalEndsWithNewline: Bool
    var modifiedEndsWithNewline: Bool
    /// Line separators to write back with ("\r\n" for CRLF files).
    var originalSeparator: String
    var modifiedSeparator: String
    var hunks: [LineDiff.Hunk]
    var originalStyles: [DiffLineStyle]
    var modifiedStyles: [DiffLineStyle]
    var originalGaps: [Int: Int]
    var modifiedGaps: [Int: Int]
    var originalRuns: [StyleRun]
    var modifiedRuns: [StyleRun]
    var addedCount: Int
    var removedCount: Int
    /// Edits to the live side when this was computed (set by the owner).
    var editCount = 0

    init(original originalText: String, modified modifiedText: String, language: Language, highlightModified: Bool) {
        self.originalText = originalText
        self.modifiedText = modifiedText
        original = LineDiff.lines(of: originalText)
        modified = LineDiff.lines(of: modifiedText)
        originalEndsWithNewline = originalText.hasSuffix("\n")
        modifiedEndsWithNewline = modifiedText.hasSuffix("\n")
        originalSeparator = originalText.contains("\r\n") ? "\r\n" : "\n"
        modifiedSeparator = modifiedText.contains("\r\n") ? "\r\n" : "\n"
        let rows = LineDiff.rows(original: original, modified: modified)
        hunks = LineDiff.hunks(rows)

        var originalStyles = [DiffLineStyle](repeating: DiffLineStyle(kind: .same), count: original.count)
        var modifiedStyles = [DiffLineStyle](repeating: DiffLineStyle(kind: .same), count: modified.count)
        var originalGaps: [Int: Int] = [:], modifiedGaps: [Int: Int] = [:]
        var pendingLeft = 0, pendingRight = 0
        var added = 0, removed = 0
        for row in rows {
            let span = row.kind == .changed ? LineDiff.changedSpan(original[row.left!], modified[row.right!]) : nil
            if let left = row.left {
                if pendingLeft > 0 { originalGaps[left] = pendingLeft; pendingLeft = 0 }
                if row.kind != .same { originalStyles[left] = DiffLineStyle(kind: .removed, emphasis: span?.old); removed += 1 }
            } else {
                pendingLeft += 1
            }
            if let right = row.right {
                if pendingRight > 0 { modifiedGaps[right] = pendingRight; pendingRight = 0 }
                if row.kind != .same { modifiedStyles[right] = DiffLineStyle(kind: .added, emphasis: span?.new); added += 1 }
            } else {
                pendingRight += 1
            }
        }
        if pendingLeft > 0 { originalGaps[original.count] = pendingLeft }
        if pendingRight > 0 { modifiedGaps[modified.count] = pendingRight }
        self.originalStyles = originalStyles
        self.modifiedStyles = modifiedStyles
        self.originalGaps = originalGaps
        self.modifiedGaps = modifiedGaps
        addedCount = added
        removedCount = removed
        originalRuns = SyntaxHighlighter.runs(for: language, in: originalText as NSString)
        modifiedRuns = highlightModified ? SyntaxHighlighter.runs(for: language, in: modifiedText as NSString) : []
    }
}

/// One side of a diff: a read-only copy of a file version, or (`sharing:`) a second view onto
/// an open document's storage, which makes it editable with that document's undo and saving.
@MainActor
final class DiffPane: NSObject, NSLayoutManagerDelegate {
    let scrollView: NSScrollView
    let textView: CodeTextView
    private let isShared: Bool
    private var runs: [StyleRun] = []

    init(sharing document: EditorDocument? = nil) {
        isShared = document != nil
        // Contiguous layout: rows line up across the panes by exact y offsets, which estimated
        // heights for not-yet-laid-out text would break.
        (scrollView, textView) = CodeTextView.makeScrollView(
            storage: document?.textStorage ?? NSTextStorage(), contiguousLayout: true)
        super.init()
        if let document {
            textView.allowsUndo = true
            textView.usesFindBar = false
            textView.lineComment = document.language.lineComment
            textView.indentUnit = document.indentUnit
            // Undo manager and dirty tracking come from the document.
            textView.delegate = document
        } else {
            textView.isEditable = false
        }
        textView.diffStyles = []
        textView.layoutManager?.delegate = self
        applyFont()
    }

    /// Replaces a read-only pane's text, keeping the scroll position.
    func show(text: String, runs: [StyleRun]) {
        guard !isShared, let storage = textView.textStorage, storage.string != text else { return }
        let origin = scrollView.contentView.bounds.origin
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        textView.invalidateLineStarts()
        self.runs = runs
        applyFont()
        scroll(to: origin)
    }

    func decorate(styles: [DiffLineStyle], gaps: [Int: Int]) {
        let gapsChanged = gaps != textView.diffGaps
        textView.diffGaps = gaps
        textView.diffStyles = styles
        if gapsChanged, let layout = textView.layoutManager, let storage = textView.textStorage {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    func applyFont() {
        let font = EditorSettings.font
        if isShared {
            // The document styles the shared storage itself; only this view's own state.
            textView.typingAttributes = [
                .font: font, .foregroundColor: Theme.editorForeground,
                .paragraphStyle: EditorSettings.paragraphStyle(for: font),
            ]
            textView.defaultParagraphStyle = EditorSettings.paragraphStyle(for: font)
        } else if let storage = textView.textStorage {
            SyntaxHighlighter.apply(runs[...], to: storage, font: textView.applyEditorFont(), force: true)
        }
        textView.diffRowHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2
        if let layout = textView.layoutManager, let storage = textView.textStorage {
            layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
        scrollView.verticalRulerView?.needsDisplay = true
    }

    /// Removes this pane's layout manager from a shared storage.
    func detach() {
        guard isShared, let layout = textView.layoutManager else { return }
        textView.textStorage?.removeLayoutManager(layout)
    }

    // MARK: Filler rows

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int,
                                   withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        MainActor.assumeIsolated {
            guard !textView.diffGaps.isEmpty else { return 0 }
            let character = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let line = textView.lineIndex(at: character)
            guard textView.lineStarts[line] == character, let rows = textView.diffGaps[line] else { return 0 }
            return CGFloat(rows) * textView.diffRowHeight
        }
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                                   withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        MainActor.assumeIsolated {
            guard !textView.diffGaps.isEmpty else { return 0 }
            let last = textView.lastTextLine
            guard let rows = textView.diffGaps[last + 1],
                  textView.lineIndex(at: layoutManager.characterIndexForGlyph(at: glyphIndex)) == last else { return 0 }
            return CGFloat(rows) * textView.diffRowHeight
        }
    }

    // MARK: Geometry and scrolling

    /// Document-space top of `line`, or with `gapFirst` of the filler rows above it; a line past
    /// the end means the filler after the last line.
    func top(ofLine line: Int, gapFirst: Bool) -> CGFloat {
        let origin = textView.textContainerOrigin.y
        let last = textView.lastTextLine
        if line > last { return textView.fragmentRect(ofLine: max(0, last)).maxY + origin }
        let rect = textView.fragmentRect(ofLine: line)
        let gap = gapFirst ? CGFloat(textView.diffGaps[line] ?? 0) * textView.diffRowHeight : 0
        return rect.minY - gap + origin
    }

    /// Where `scroll(toY:)` places a target: a few rows below the top edge.
    func revealAnchor() -> CGFloat {
        let clip = scrollView.contentView
        return clip.bounds.minY + clip.contentInsets.top + 3 * textView.diffRowHeight
    }

    func scroll(toY y: CGFloat) {
        scroll(to: NSPoint(x: -.greatestFiniteMagnitude, y: y - 3 * textView.diffRowHeight))
    }

    /// Scrolls the clip view, clamped to its content insets: the line-number ruler floats over
    /// the clip view, which reserves it as a negative-x inset, so x = 0 would hide the text's
    /// first columns beneath the ruler.
    func scroll(to point: NSPoint) {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let document = textView.frame.size
        let x = min(max(point.x, -insets.left), max(-insets.left, document.width - clip.bounds.width + insets.right))
        let y = min(max(point.y, -insets.top), max(-insets.top, document.height - clip.bounds.height + insets.bottom))
        clip.scroll(to: NSPoint(x: x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
