import AppKit
import LiteCodeCore
import Observation

/// State of one editor's find/replace widget (⌘F / ⌥⌘F), shown in the editor's top-right
/// corner like VS Code's. Matches are painted as layout-manager temporary attributes, which
/// don't touch the text storage, undo, or layout.
@MainActor
@Observable
final class FindModel {
    /// Past this many matches the count reads "10000+" and later matches aren't highlighted.
    static let limit = 10_000

    private(set) var isVisible = false
    var showReplace = false
    /// Replacing needs an editable target.
    var canReplace: Bool { textView?.isEditable ?? false }
    var query = "" { didSet { if query != oldValue { refresh(reveal: true) } } }
    var replacement = ""
    var caseSensitive = false { didSet { if caseSensitive != oldValue { refresh(reveal: true) } } }
    var wholeWord = false { didSet { if wholeWord != oldValue { refresh(reveal: true) } } }
    var regex = false { didSet { if regex != oldValue { refresh(reveal: true) } } }
    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?
    private(set) var isInvalid = false
    /// Bumped to move keyboard focus into the find field.
    private(set) var focusRequest = 0
    /// How that focus lands: select the old query, or caret after a freshly seeded one.
    private(set) var selectsQueryOnFocus = true

    @ObservationIgnored weak var textView: CodeTextView?
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var highlighted = false

    var summary: String {
        guard let currentIndex else { return "No results" }
        let total = matches.count >= Self.limit ? "\(Self.limit)+" : "\(matches.count)"
        return "\(currentIndex + 1) of \(total)"
    }

    /// Opens the widget, seeding the query from a single-line selection, and focuses the field:
    /// caret at the end of a seeded query, otherwise the previous query selected.
    func open(replace: Bool) {
        let selected = textView?.selectedSearchText
        if let selected {
            query = regex ? NSRegularExpression.escapedPattern(for: selected) : selected
        }
        selectsQueryOnFocus = selected == nil
        if replace { showReplace = true }
        isVisible = true
        focusRequest += 1
        refresh(reveal: false)
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        refreshWork?.cancel()
        clearHighlights()
        if let textView { textView.window?.makeFirstResponder(textView) }
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Replaces the current match, then moves to the following one.
    func replaceCurrent() {
        guard let textView, let currentIndex, let expression = try? options.expression() else { return }
        let range = matches[currentIndex]
        let text = textView.characters
        guard let match = expression.firstMatch(in: text as String, options: [.anchored, .withTransparentBounds], range: range),
              match.range == range else { refresh(reveal: true); return }
        let replaced = replacementString(for: match, expression: expression, in: text)
        textView.insertText(replaced, replacementRange: range)
        recompute()
        guard !matches.isEmpty else { return }
        let after = range.location + (replaced as NSString).length
        self.currentIndex = matches.firstIndex { $0.location >= after } ?? 0
        reveal()
    }

    /// Replaces every match as one undoable edit.
    func replaceAll() {
        guard let textView, let storage = textView.textStorage, let expression = try? options.expression() else { return }
        let text = textView.characters
        let found = expression.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .filter { $0.range.length > 0 }
        guard !found.isEmpty else { return }
        let ranges = found.map { NSValue(range: $0.range) }
        let strings = found.map { replacementString(for: $0, expression: expression, in: text) }
        guard textView.shouldChangeText(inRanges: ranges, replacementStrings: strings) else { return }
        storage.beginEditing()
        for (match, string) in zip(found, strings).reversed() {
            storage.replaceCharacters(in: match.range, with: string)
        }
        storage.endEditing()
        textView.didChangeText()
        recompute()
    }

    /// Called on every edit: match positions shift, so recount once typing pauses.
    func textDidChange() {
        guard isVisible, !query.isEmpty else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recompute() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: Private

    private var options: SearchOptions {
        SearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex)
    }

    /// Recounts and, when `reveal`, jumps to the first match at or after the cursor (as typing
    /// in the field does in VS Code).
    private func refresh(reveal shouldReveal: Bool) {
        guard isVisible else { return }
        recompute()
        if shouldReveal { reveal() }
    }

    /// Recomputes matches and keeps the current one nearest the selection, without moving it.
    private func recompute() {
        guard let textView else { return }
        isInvalid = false
        guard !query.isEmpty else { setMatches([], current: nil); return }
        guard let expression = try? options.expression() else {
            isInvalid = true
            setMatches([], current: nil)
            return
        }
        let text = textView.characters
        var found: [NSRange] = []
        expression.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            found.append(match.range)
            if found.count >= Self.limit { stop.pointee = true }
        }
        let anchor = textView.selectedRange().location
        let current = found.isEmpty ? nil : (found.firstIndex { $0.location >= anchor } ?? 0)
        setMatches(found, current: current)
    }

    private func setMatches(_ found: [NSRange], current: Int?) {
        matches = found
        currentIndex = current
        paintHighlights()
    }

    private func step(by offset: Int) {
        guard let textView else { return }
        if !isVisible {
            // ⌘G with the widget closed reuses the last query, like VS Code.
            guard !query.isEmpty else { open(replace: false); return }
            isVisible = true
        }
        recompute()
        guard !matches.isEmpty else { return }
        let selection = textView.selectedRange()
        if offset > 0 {
            let start = NSMaxRange(selection)
            currentIndex = matches.firstIndex { $0.location >= start && $0 != selection } ?? 0
        } else {
            currentIndex = matches.lastIndex { $0.location < selection.location } ?? matches.count - 1
        }
        reveal()
    }

    private func reveal() {
        guard let textView, let currentIndex else { return }
        let range = matches[currentIndex]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        paintHighlights()
    }

    private func paintHighlights() {
        guard let layout = textView?.layoutManager else { return }
        clearHighlights()
        guard isVisible else { return }
        for (index, range) in matches.enumerated() {
            let color = index == currentIndex ? Theme.findMatch : Theme.searchMatch
            layout.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
        }
        highlighted = !matches.isEmpty
    }

    private func clearHighlights() {
        guard highlighted, let textView, let layout = textView.layoutManager else { return }
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: textView.characters.length))
        highlighted = false
    }

    private func replacementString(for match: NSTextCheckingResult, expression: NSRegularExpression, in text: NSString) -> String {
        // Templates ($1, \n escapes) only apply in regex mode; otherwise the text is literal.
        guard regex else { return replacement }
        return expression.replacementString(for: match, in: text as String, offset: 0, template: replacement)
    }
}
