import AppKit
import LiteCodeCore
import Observation

/// An open text file. Owns its text view so undo history, selection, and scroll position
/// survive tab switches.
@MainActor
@Observable
final class EditorDocument: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    private(set) var url: URL
    private(set) var isDirty = false
    private(set) var isBinary = false
    private(set) var loadError: String?
    private(set) var cursorLine = 1
    private(set) var cursorColumn = 1
    let language: Language
    /// Indent unit inferred from the file: a tab, two spaces, or four spaces.
    private(set) var indentUnit = "    "

    @ObservationIgnored private var savedText = "" {
        didSet { savedCharacters = NSString(string: savedText) }
    }
    /// UTF-16 copy of `savedText`: comparing NSStrings is a memcmp, while `String ==` runs
    /// Unicode normalization over the whole file on every keystroke.
    @ObservationIgnored private var savedCharacters: NSString = ""
    @ObservationIgnored private var savedModificationDate: Date?
    @ObservationIgnored private var highlightWork: DispatchWorkItem?
    /// Bumped on every character edit, so a background highlight pass started on an older
    /// snapshot is dropped instead of painting stale ranges.
    @ObservationIgnored private var editGeneration = 0
    /// Runs last written to the storage, so the next pass only restyles what changed.
    @ObservationIgnored private var appliedRuns: [StyleRun]?
    private static let highlightQueue = DispatchQueue(label: "LiteCode.highlight", qos: .userInitiated)
    @ObservationIgnored private var _scrollView: NSScrollView?
    @ObservationIgnored private(set) var textView: CodeTextView?
    /// Per-document: the window's shared undo manager would let ⌘Z in one tab undo another tab.
    @ObservationIgnored private let undoManager = UndoManager()
    let find = FindModel()
    /// Index (staged) version of the file, split into lines, for the gutter's change markers;
    /// nil when the file isn't in the index.
    @ObservationIgnored private var baseLines: [String]?
    @ObservationIgnored private var gutterWork: DispatchWorkItem?
    /// Selection to show once the text view is on screen (search results, go-to-line).
    @ObservationIgnored private var pendingReveal: (line: Int, range: NSRange)?
    /// Saves this document for auto save; set by the owning workspace.
    @ObservationIgnored var autoSaveHandler: ((EditorDocument) -> Void)?
    @ObservationIgnored private var autoSaveWork: DispatchWorkItem?

    var name: String { url.lastPathComponent }

    init(url: URL) {
        self.url = url
        language = Language.detect(url)
        super.init()
        savedText = readDisk() ?? ""
        savedCharacters = NSString(string: savedText)
        indentUnit = Self.detectIndent(savedText)
    }

    /// Reads the file, flagging binary content. Returns nil for binary or unreadable files.
    private func readDisk() -> String? {
        do {
            let data = try Data(contentsOf: url)
            savedModificationDate = modificationDate()
            loadError = nil
            if data.prefix(8000).contains(0) {
                isBinary = true
                return nil
            }
            isBinary = false
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    private func modificationDate() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    var scrollView: NSScrollView {
        if let _scrollView { return _scrollView }
        let scroll = makeScrollView()
        _scrollView = scroll
        return scroll
    }

    /// The document's text storage, created with its editor view on first use. Diff panes add
    /// their own layout managers to it, so edits there are edits to this document.
    var textStorage: NSTextStorage {
        _ = scrollView
        return textView!.textStorage!
    }

    private func makeScrollView() -> NSScrollView {
        let (scroll, textView) = CodeTextView.makeScrollView(text: savedText)
        let storage = textView.textStorage!
        textView.allowsUndo = true
        // Our own find widget (FindModel/FindWidget) replaces the system find bar.
        textView.usesFindBar = false
        textView.lineComment = language.lineComment
        textView.indentUnit = indentUnit
        textView.delegate = self
        textView.onResignFocus = { [weak self] in self?.autoSave(on: .onFocusChange) }
        storage.delegate = self
        self.textView = textView
        find.textView = textView
        textView.onCancel = { [weak self] in
            guard let self, self.find.isVisible else { return false }
            self.find.close()
            return true
        }
        applyFont()
        recomputeGutter()

        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewScrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    @objc private func clipViewScrolled() {
        _scrollView?.verticalRulerView?.needsDisplay = true
    }

    private static func detectIndent(_ text: String) -> String {
        var tabs = 0, spaces = 0
        for line in text.split(separator: "\n", maxSplits: 2000, omittingEmptySubsequences: true) {
            if line.hasPrefix("\t") { tabs += 1 } else if line.hasPrefix("  ") { spaces += 1 }
        }
        if tabs > spaces { return "\t" }
        // Two-space files (JS/YAML/Ruby) indent by two; otherwise four.
        var twoSpace = 0, fourSpace = 0
        for line in text.split(separator: "\n", maxSplits: 2000, omittingEmptySubsequences: true) where line.hasPrefix("  ") {
            let count = line.prefix { $0 == " " }.count
            if count % 4 == 0 { fourSpace += 1 } else if count % 2 == 0 { twoSpace += 1 }
        }
        return twoSpace > fourSpace / 2 && twoSpace > 0 ? "  " : "    "
    }

    func applyFont() {
        guard let textView, let storage = textView.textStorage else { return }
        let font = textView.applyEditorFont()
        let runs = SyntaxHighlighter.runs(for: language, in: textView.characters)
        SyntaxHighlighter.apply(runs[...], to: storage, font: font, force: true)
        appliedRuns = runs
        _scrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Re-tokenizes a snapshot on a background queue once typing pauses, then restyles only
    /// the runs that changed.
    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let textView = self.textView else { return }
            // An immutable copy, safe to read on the highlight queue.
            nonisolated(unsafe) let snapshot = textView.characters.copy() as! NSString
            let generation = self.editGeneration
            let language = self.language
            Self.highlightQueue.async { [weak self] in
                let runs = SyntaxHighlighter.runs(for: language, in: snapshot)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.editGeneration == generation,
                              let storage = self.textView?.textStorage else { return }
                        let changed = SyntaxHighlighter.changedRange(old: self.appliedRuns, new: runs)
                        SyntaxHighlighter.apply(runs[changed], to: storage, font: EditorSettings.font, force: false)
                        self.appliedRuns = runs
                    }
                }
            }
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // MARK: Disk sync

    func save() throws {
        guard let textView else { return }
        let text = textView.string
        try text.write(to: url, atomically: true, encoding: .utf8)
        savedText = text
        savedModificationDate = modificationDate()
        isDirty = false
    }

    /// Picks up external edits (git checkout, formatter, another editor) unless the user has
    /// unsaved changes in this buffer.
    func reloadIfChangedOnDisk() {
        guard !isDirty, modificationDate() != savedModificationDate else { return }
        guard let text = readDisk(), text != savedText else { return }
        savedText = text
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        // The replacement restyled everything uniformly, so the last applied runs no longer
        // describe the storage; the highlight pass this edit schedules must check every run.
        appliedRuns = nil
        undoManager.removeAllActions()
        let length = storage.length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func moved(to newURL: URL) {
        url = newURL
    }

    // MARK: Auto save

    /// Saves now if the current auto-save mode is `trigger` (or, for focus changes, the editor
    /// also counts as losing focus when the window does).
    func autoSave(on trigger: AutoSaveMode) {
        let mode = EditorSettings.autoSave
        guard isDirty, mode != .off,
              mode == trigger || (trigger == .onWindowChange && mode == .onFocusChange) else { return }
        autoSaveWork?.cancel()
        autoSaveHandler?(self)
    }

    /// `afterDelay`: save once typing has paused for `files.autoSaveDelay`.
    private func scheduleAutoSave() {
        autoSaveWork?.cancel()
        guard isDirty, EditorSettings.autoSave == .afterDelay else { return }
        let work = DispatchWorkItem { [weak self] in self?.autoSave(on: .afterDelay) }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditorSettings.autoSaveDelay, execute: work)
    }

    // MARK: Gutter change markers

    /// Sets the HEAD version to compare against (nil: untracked or outside a repository).
    func setBase(_ text: String?) {
        baseLines = text.map(LineDiff.lines(of:))
        recomputeGutter()
    }

    private func scheduleGutter() {
        guard baseLines != nil else { return }
        gutterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeGutter() }
        gutterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func recomputeGutter() {
        guard let textView else { return }
        if let baseLines, textView.characters.length <= SyntaxHighlighter.maxLength {
            textView.gutterMarks = GutterMarks.compute(base: baseLines, current: LineDiff.lines(of: textView.string))
        } else {
            textView.gutterMarks = GutterMarks()
        }
        _scrollView?.verticalRulerView?.needsDisplay = true
    }

    // MARK: Reveal

    /// Selects `range` (UTF-16, within the line) on 0-based `line` and scrolls to it, now if the
    /// editor is on screen or as soon as it is shown.
    func reveal(line: Int, range: NSRange) {
        pendingReveal = (line, range)
        if textView?.window != nil { applyPendingReveal() }
    }

    func applyPendingReveal() {
        guard let pendingReveal, let textView else { return }
        self.pendingReveal = nil
        let starts = textView.lineStarts
        let start = starts[min(max(pendingReveal.line, 0), starts.count - 1)]
        let length = textView.characters.length
        let location = min(start + pendingReveal.range.location, length)
        let target = NSRange(location: location, length: min(pendingReveal.range.length, length - location))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
    }

    // MARK: Delegates

    func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            editGeneration += 1
            find.textDidChange()
            textView?.invalidateLineStarts()
            let characters = textStorage.mutableString
            let dirty = characters.length != savedCharacters.length || !characters.isEqual(savedCharacters)
            // Observation notifies on every assignment, even of an equal value; each
            // notification re-renders the tab bars, so only write real changes.
            if dirty != isDirty { isDirty = dirty }
            _scrollView?.verticalRulerView?.needsDisplay = true
            scheduleHighlight()
            scheduleGutter()
            scheduleAutoSave()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Diff panes editing this document share the delegate; only the editor's own caret feeds
        // the status bar.
        guard let textView, notification.object as AnyObject? === textView else { return }
        let location = textView.selectedRange().location
        let line = textView.lineIndex(at: location)
        let column = location - textView.lineStarts[line] + 1
        if cursorLine != line + 1 { cursorLine = line + 1 }
        if cursorColumn != column { cursorColumn = column }
        _scrollView?.verticalRulerView?.needsDisplay = true
    }
}
