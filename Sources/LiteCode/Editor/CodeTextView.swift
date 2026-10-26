import AppKit
import LiteCodeCore

/// Line decoration when a code view shows one side of a diff.
struct DiffLineStyle: Sendable {
    enum Kind: Sendable { case same, removed, added }
    var kind: Kind
    /// Changed characters within the line (UTF-16 offsets), drawn with a stronger tint.
    var emphasis: Range<Int>?
}

/// Plain-text code view: auto-indent, indent/outdent, and line-comment toggling.
final class CodeTextView: NSTextView {
    /// Per-line styles when this view is one side of a diff; nil in normal editors.
    var diffStyles: [DiffLineStyle]? {
        didSet { needsDisplay = true; enclosingScrollView?.verticalRulerView?.needsDisplay = true }
    }
    /// Diff filler: rows the other side has here, keyed by the line they precede (the line
    /// count means after the last line). The diff pane's layout delegate reserves the space as
    /// paragraph spacing, so the text itself stays the real file.
    var diffGaps: [Int: Int] = [:]
    /// Height of one filler row: the font's default line height.
    var diffRowHeight: CGFloat = 0
    var lineComment: String?
    /// Indent unit inferred from the file: a tab or four spaces.
    var indentUnit = "    "
    /// Git change markers drawn by the line-number ruler.
    var gutterMarks = GutterMarks()
    /// Called when the editor gives up keyboard focus (auto save "onFocusChange").
    var onResignFocus: (() -> Void)?
    /// Escape handler; returns true when it consumed the key (closing the find widget).
    var onCancel: (() -> Bool)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFocus?() }
        return resigned
    }

    override func cancelOperation(_ sender: Any?) {
        if onCancel?() != true { super.cancelOperation(sender) }
    }

    private var cachedLineStarts: [Int]?

    /// The storage's characters without bridging: `string` copies the whole buffer into a new
    /// Swift String on every access, which shows up per keystroke in large files.
    var characters: NSString { textStorage?.mutableString ?? "" }

    /// The selection as a search query (⌘F, ⇧⌘F): only a non-empty, single-line selection under
    /// 500 characters, as VS Code seeds its find widgets.
    var selectedSearchText: String? {
        let selection = selectedRange()
        guard selection.length > 0, selection.length < 500 else { return nil }
        let text = characters.substring(with: selection)
        return text.contains("\n") || text.contains("\r") ? nil : text
    }

    /// UTF-16 offsets where each line starts; rebuilt lazily after edits. A trailing newline
    /// yields a final start equal to the length (the empty last line).
    var lineStarts: [Int] {
        if let cachedLineStarts { return cachedLineStarts }
        let text = characters
        let length = text.length
        var starts = [0]
        starts.reserveCapacity(length / 32 + 1)
        var buffer = [unichar](repeating: 0, count: 16_384)
        var offset = 0
        while offset < length {
            let count = min(buffer.count, length - offset)
            text.getCharacters(&buffer, range: NSRange(location: offset, length: count))
            for index in 0..<count where buffer[index] == 10 {
                starts.append(offset + index + 1)
            }
            offset += count
        }
        cachedLineStarts = starts
        return starts
    }

    /// Called by the owning document whenever the storage's characters change (typing, undo, reload).
    func invalidateLineStarts() {
        cachedLineStarts = nil
    }

    // MARK: Background decorations

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawDiffBackgrounds(in: rect)
        drawCurrentLineHighlight(in: rect)
        drawIndentGuides(in: rect)
    }

    /// Line fragment of a 0-based line without diff filler spacing, in text-container coordinates.
    func fragmentRect(ofLine line: Int) -> NSRect {
        var rect = rawFragmentRect(ofLine: line)
        guard !diffGaps.isEmpty, !rect.isEmpty else { return rect }
        let before = CGFloat(diffGaps[line] ?? 0) * diffRowHeight
        let after = line == lastTextLine ? CGFloat(diffGaps[lastTextLine + 1] ?? 0) * diffRowHeight : 0
        rect.origin.y += before
        rect.size.height -= before + after
        return rect
    }

    /// Index of the last line holding characters (a trailing newline's empty line excluded).
    var lastTextLine: Int {
        let starts = lineStarts
        return starts.count > 1 && starts[starts.count - 1] >= characters.length ? starts.count - 2 : starts.count - 1
    }

    private func rawFragmentRect(ofLine line: Int) -> NSRect {
        guard let layout = layoutManager else { return .zero }
        let start = lineStarts[line]
        if start >= characters.length { return layout.extraLineFragmentRect }
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
    }

    /// Lines intersecting `rect` (view coordinates).
    private func visibleLines(in rect: NSRect) -> ClosedRange<Int>? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(
            forBoundingRect: NSRect(x: 0, y: rect.minY - origin.y, width: .greatestFiniteMagnitude, height: rect.height),
            in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return lineIndex(at: chars.location)...lineIndex(at: NSMaxRange(chars))
    }

    /// VS Code diff look: tinted changed lines, a stronger tint on the edited characters, and
    /// diagonal hatching where the other side has lines this one lacks.
    private func drawDiffBackgrounds(in rect: NSRect) {
        guard let styles = diffStyles, let layout = layoutManager, let lines = visibleLines(in: rect) else { return }
        let origin = textContainerOrigin
        for line in lines {
            let raw = rawFragmentRect(ofLine: line)
            guard !raw.isEmpty else { continue }
            var row = fragmentRect(ofLine: line)
            row.origin.x = 0
            row.origin.y += origin.y
            row.size.width = bounds.width
            if diffGaps[line] != nil {
                drawHatch(in: NSRect(x: 0, y: raw.minY + origin.y, width: bounds.width, height: row.minY - raw.minY - origin.y)
                    .intersection(rect))
            }
            if line == lastTextLine, diffGaps[line + 1] != nil {
                drawHatch(in: NSRect(x: 0, y: row.maxY, width: bounds.width, height: raw.maxY + origin.y - row.maxY)
                    .intersection(rect))
            }
            guard line < styles.count, styles[line].kind != .same else { continue }
            let style = styles[line]
            (style.kind == .removed ? Theme.diffRemoved : Theme.diffInserted).setFill()
            row.intersection(rect).fill(using: .sourceOver)
            if let emphasis = style.emphasis, !emphasis.isEmpty,
               lineStarts[line] + emphasis.upperBound <= characters.length {
                let chars = NSRange(location: lineStarts[line] + emphasis.lowerBound, length: emphasis.count)
                let glyphs = layout.glyphRange(forCharacterRange: chars, actualCharacterRange: nil)
                var box = layout.boundingRect(forGlyphRange: glyphs, in: textContainer!)
                box.origin.x += origin.x
                box.origin.y = row.minY
                box.size.height = row.height
                (style.kind == .removed ? Theme.diffRemovedText : Theme.diffInsertedText).setFill()
                box.intersection(rect).fill(using: .sourceOver)
            }
        }
    }

    private func drawHatch(in rect: NSRect) {
        guard !rect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let stripes = NSBezierPath()
        // Stripes lie on x + y = c for multiples of the spacing, so they continue seamlessly
        // across rows and redraws.
        let spacing: CGFloat = 8
        var c = ((rect.minX + rect.minY) / spacing).rounded(.down) * spacing
        while c <= rect.maxX + rect.maxY {
            stripes.move(to: NSPoint(x: c - rect.maxY, y: rect.maxY))
            stripes.line(to: NSPoint(x: c - rect.minY, y: rect.minY))
            c += spacing
        }
        stripes.lineWidth = 1
        Theme.diffFiller.setStroke()
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCurrentLineHighlight(in rect: NSRect) {
        guard selectedRange().length == 0 else { return }
        var line = fragmentRect(ofLine: lineIndex(at: selectedRange().location))
        guard !line.isEmpty else { return }
        line.origin.x = 0
        line.origin.y += textContainerOrigin.y
        line.size.width = bounds.width
        Theme.lineHighlight.setFill()
        line.intersection(rect).fill()
    }

    // MARK: Indent guides

    /// How far the blank-line and active-block scans may walk, so pathological files stay cheap.
    private static let guideScanLimit = 5000

    /// Columns between guides: one indent unit.
    private var guideStep: Int { indentUnit == "\t" ? EditorSettings.tabWidth : max(1, indentUnit.count) }

    /// Width of a line's leading whitespace in columns, or nil for a blank line.
    private func indentColumns(ofLine line: Int, _ starts: [Int], _ text: NSString) -> Int? {
        let end = line + 1 < starts.count ? starts[line + 1] : text.length
        var columns = 0
        var index = starts[line]
        while index < end {
            switch text.character(at: index) {
            case 32: columns += 1
            case 9: columns += EditorSettings.tabWidth - columns % EditorSettings.tabWidth
            case 10, 13: return nil
            default: return columns
            }
            index += 1
        }
        return nil
    }

    /// Indent that decides a line's guides. Blank lines take the deeper of the nearest
    /// non-blank lines around them, so guides run unbroken through gaps inside a block.
    private func guideColumns(ofLine line: Int, _ starts: [Int], _ text: NSString) -> Int {
        if let columns = indentColumns(ofLine: line, starts, text) { return columns }
        var above = 0, below = 0
        for k in stride(from: line - 1, through: max(0, line - Self.guideScanLimit), by: -1) {
            if let columns = indentColumns(ofLine: k, starts, text) { above = columns; break }
        }
        for k in (line + 1)..<min(starts.count, line + Self.guideScanLimit) {
            if let columns = indentColumns(ofLine: k, starts, text) { below = columns; break }
        }
        return max(above, below)
    }

    /// The guide of the innermost block around the caret, as VS Code highlights it: on a line
    /// that opens a deeper block, the guide of that child block.
    private func activeGuide(_ starts: [Int], _ text: NSString) -> (column: Int, lines: ClosedRange<Int>)? {
        let step = guideStep
        let caret = lineIndex(at: selectedRange().location)
        let caretColumns = guideColumns(ofLine: caret, starts, text)
        var nextColumns: Int?
        for k in (caret + 1)..<min(starts.count, caret + Self.guideScanLimit) {
            if let columns = indentColumns(ofLine: k, starts, text) { nextColumns = columns; break }
        }

        let column: Int
        var first = caret
        if indentColumns(ofLine: caret, starts, text) != nil, let nextColumns, nextColumns > caretColumns {
            column = caretColumns / step * step
            first = caret + 1
        } else {
            guard caretColumns > 0 else { return nil }
            column = (caretColumns - 1) / step * step
        }
        guard first < starts.count, guideColumns(ofLine: first, starts, text) > column else { return nil }
        var last = first
        let lowerBound = max(0, first - Self.guideScanLimit)
        let upperBound = min(starts.count - 1, last + Self.guideScanLimit)
        while first > lowerBound, guideColumns(ofLine: first - 1, starts, text) > column { first -= 1 }
        while last < upperBound, guideColumns(ofLine: last + 1, starts, text) > column { last += 1 }
        return (column, first...last)
    }

    private func drawIndentGuides(in rect: NSRect) {
        let text = characters
        guard text.length > 0, let layout = layoutManager, let container = textContainer, let font else { return }
        let origin = textContainerOrigin
        let glyphs = layout.glyphRange(
            forBoundingRect: NSRect(x: 0, y: rect.minY - origin.y, width: .greatestFiniteMagnitude, height: rect.height),
            in: container)
        guard glyphs.length > 0 else { return }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let starts = lineStarts
        let step = guideStep
        let columnWidth = EditorSettings.spaceWidth(font)
        let left = origin.x + container.lineFragmentPadding
        let active = activeGuide(starts, text)

        let lastLine = lineIndex(at: NSMaxRange(chars))
        for line in lineIndex(at: chars.location)...lastLine where starts[line] < text.length {
            let fragment = fragmentRect(ofLine: line)
            let columns = guideColumns(ofLine: line, starts, text)
            for column in stride(from: 0, to: columns, by: step) {
                let isActive = active.map { $0.column == column && $0.lines.contains(line) } ?? false
                (isActive ? Theme.indentGuideActive : Theme.indentGuide).setFill()
                let x = (left + CGFloat(column) * columnWidth).rounded(.down)
                // Guide colors are translucent; .fill() would copy rather than blend them.
                NSRect(x: x, y: fragment.minY + origin.y, width: 1, height: fragment.height).fill(using: .sourceOver)
            }
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsDisplay(visibleRect)
    }

    /// 0-based line containing a UTF-16 offset.
    func lineIndex(at location: Int) -> Int {
        let starts = lineStarts
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Editing commands

    override func insertNewline(_ sender: Any?) {
        let ns = characters
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        var indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })
        if let last = beforeCaret.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) {
            indent += indentUnit
        }
        insertText("\n" + indent, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if spansMultipleLines() {
            indentSelection()
        } else {
            insertText(indentUnit, replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) { outdentSelection() }

    private func spansMultipleLines() -> Bool {
        characters.substring(with: selectedRange()).contains("\n")
    }

    private func selectedLinesRange() -> NSRange {
        characters.lineRange(for: selectedRange())
    }

    /// Rewrites every selected line through `transform` as one undoable edit.
    private func transformSelectedLines(_ transform: ([String]) -> [String]) {
        let ns = characters
        var range = selectedLinesRange()
        var block = ns.substring(with: range)
        let trailingNewline = block.hasSuffix("\n")
        if trailingNewline { block.removeLast() }
        var replacement = transform(block.components(separatedBy: "\n")).joined(separator: "\n")
        if trailingNewline { replacement += "\n" }
        guard replacement != ns.substring(with: range), shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        range.length = (replacement as NSString).length - (trailingNewline ? 1 : 0)
        setSelectedRange(range)
    }

    func indentSelection() {
        let unit = indentUnit
        transformSelectedLines { $0.map { $0.isEmpty ? $0 : unit + $0 } }
    }

    func outdentSelection() {
        let width = indentUnit.count
        transformSelectedLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, width)))
            }
        }
    }

    func toggleLineComment() {
        guard let token = lineComment else { NSSound.beep(); return }
        transformSelectedLines { lines in
            let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let commented = !content.isEmpty && content.allSatisfy {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(token)
            }
            let column = content.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if commented {
                    guard let range = line.range(of: token) else { return line }
                    var end = range.upperBound
                    if end < line.endIndex, line[end] == " " { end = line.index(after: end) }
                    return line.replacingCharacters(in: range.lowerBound..<end, with: "")
                }
                let split = line.index(line.startIndex, offsetBy: column)
                return line[..<split] + token + " " + line[split...]
            }
        }
    }
}

/// Gutter that draws 1-based line numbers for a `CodeTextView`.
final class LineNumberRuler: NSRulerView {
    private weak var codeView: CodeTextView?

    init(textView: CodeTextView) {
        codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
        // NSView no longer clips by default; without this, numbers for lines scrolled above the
        // viewport paint over the tab bar.
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Laid-out line numbers, keyed by number and whether it is the caret's line. Drawing
    /// through NSString re-ran text layout for every visible label on every keystroke and caret
    /// move (~10 ms per redraw in a 2,500-line file); a cached CTLine draws in microseconds.
    private struct Label {
        var line: CTLine
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
    }

    private var labelFont: NSFont?
    private var digitWidth: CGFloat = 7
    private var labels: [Int: Label] = [:]
    private var currentLabels: [Int: Label] = [:]
    private var signLabels: [DiffLineStyle.Kind: Label] = [:]

    private func prepareFont() -> NSFont {
        let size = max(9, (codeView?.font?.pointSize ?? 13) - 2)
        if let labelFont, labelFont.pointSize == size { return labelFont }
        let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        labelFont = font
        digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        labels = [:]
        currentLabels = [:]
        signLabels = [:]
        return font
    }

    private func label(_ number: Int, current: Bool, font: NSFont) -> Label {
        if let cached = current ? currentLabels[number] : labels[number] { return cached }
        let text = NSAttributedString(string: String(number), attributes: [
            .font: font, .foregroundColor: current ? Theme.lineNumberActive : Theme.lineNumber,
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let label = Label(line: line, width: width, ascent: ascent, descent: descent)
        if current { currentLabels[number] = label } else { labels[number] = label }
        return label
    }

    /// Diff gutter sign: "+" for inserted lines, "−" for removed ones.
    private func marker(_ kind: DiffLineStyle.Kind, font: NSFont) -> Label? {
        guard kind == .added || kind == .removed else { return nil }
        if let cached = signLabels[kind] { return cached }
        let text = NSAttributedString(string: kind == .added ? "+" : "−", attributes: [
            .font: font, .foregroundColor: kind == .added ? Theme.gitAdded : Theme.gitDeleted,
        ])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let label = Label(line: line, width: width, ascent: ascent, descent: descent)
        signLabels[kind] = label
        return label
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView, let layout = textView.layoutManager, let container = textView.textContainer,
              let scrollView, let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.editorBackground.setFill()
        bounds.fill()

        let font = prepareFont()
        let starts = textView.lineStarts
        let digits = max(3, String(starts.count).count)
        let thickness = (CGFloat(digits) * digitWidth + 24).rounded(.up)
        if abs(thickness - ruleThickness) > 0.5 {
            ruleThickness = thickness
            return
        }

        let visible = scrollView.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = textView.lineIndex(at: textView.selectedRange().location)
        let inset = textView.textContainerOrigin.y
        let length = textView.characters.length

        // The ruler is flipped; CoreText draws with y up, so flip glyphs back.
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var line = textView.lineIndex(at: chars.location)
        while line < starts.count {
            let start = starts[line]
            let fragment = textView.fragmentRect(ofLine: line)
            if start >= length && fragment.isEmpty && length > 0 { break }
            let y = convert(NSPoint(x: 0, y: fragment.minY + inset), from: textView).y
            if y > bounds.maxY { break }
            let style = textView.diffStyles.flatMap { line < $0.count ? $0[line] : nil }
            let label = label(line + 1, current: line == caretLine, font: font)
            let baseline = y + (fragment.height + label.ascent - label.descent) / 2
            context.textPosition = CGPoint(x: ruleThickness - label.width - 12, y: baseline)
            CTLineDraw(label.line, context)
            if let style {
                if let sign = marker(style.kind, font: font) {
                    context.textPosition = CGPoint(x: ruleThickness - 10, y: y + (fragment.height + sign.ascent - sign.descent) / 2)
                    CTLineDraw(sign.line, context)
                }
            } else {
                drawChangeMarker(line: line, top: y, height: fragment.height, marks: textView.gutterMarks)
            }
            line += 1
            if start >= length { break }
        }
        context.restoreGState()
    }

    /// VS Code's quick-diff decorations: a solid bar for added lines, a hatched bar for modified
    /// ones, and a small triangle where lines were deleted.
    private func drawChangeMarker(line: Int, top: CGFloat, height: CGFloat, marks: GutterMarks) {
        let bar = NSRect(x: ruleThickness - 7, y: top, width: 3, height: height)
        if marks.added.contains(line) {
            Theme.gutterAdded.setFill()
            bar.fill()
        } else if marks.modified.contains(line) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bar).addClip()
            Theme.gutterModified.withAlphaComponent(0.35).setFill()
            bar.fill()
            let stripes = NSBezierPath()
            var offset = -bar.width
            while offset < bar.height {
                stripes.move(to: NSPoint(x: bar.minX, y: bar.minY + offset + bar.width))
                stripes.line(to: NSPoint(x: bar.maxX, y: bar.minY + offset))
                offset += 3
            }
            stripes.lineWidth = 1.2
            Theme.gutterModified.setStroke()
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        if marks.deletedBefore.contains(line) {
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: bar.minX - 1, y: top - 4))
            triangle.line(to: NSPoint(x: bar.minX - 1, y: top + 4))
            triangle.line(to: NSPoint(x: bar.minX + 4, y: top))
            triangle.close()
            Theme.gutterDeleted.setFill()
            triangle.fill()
        }
    }
}

extension CodeTextView {
    /// A themed, non-wrapping code view (TextKit 1: the ruler walks NSLayoutManager fragments)
    /// inside a hover scroll view with a line-number ruler.
    static func makeScrollView(text: String) -> (NSScrollView, CodeTextView) {
        makeScrollView(storage: NSTextStorage(string: text))
    }

    /// A code view onto `storage`, which may already back another view (a diff pane showing the
    /// same document as its editor tab). `contiguousLayout` lays out the whole text, which diff
    /// panes need so rows line up by exact y offsets.
    static func makeScrollView(storage: NSTextStorage, contiguousLayout: Bool = false) -> (NSScrollView, CodeTextView) {
        let layout = NSLayoutManager()
        // Lay out only what is on screen: attribute changes from highlighting otherwise force a
        // relayout of everything above the visible lines.
        layout.allowsNonContiguousLayout = !contiguousLayout
        let container = NSTextContainer(containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        layout.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.backgroundColor = Theme.editorBackground
        textView.drawsBackground = true
        textView.insertionPointColor = Theme.cursor
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        // Attach the text last and, for contiguous views, lay it out in one pass: a view that
        // already holds text otherwise lays it out again for its configuration and while it
        // resizes, 280ms instead of 45ms for a 1,400-line diff pane.
        storage.addLayoutManager(layout)
        if contiguousLayout { layout.ensureLayout(for: container) }

        let scroll = HoverScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.verticalRulerView = LineNumberRuler(textView: textView)
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        return (scroll, textView)
    }

    /// Applies the editor font settings and returns the font to highlight with.
    func applyEditorFont() -> NSFont {
        let font = EditorSettings.font
        self.font = font
        typingAttributes = [
            .font: font, .foregroundColor: Theme.editorForeground,
            .paragraphStyle: EditorSettings.paragraphStyle(for: font),
        ]
        defaultParagraphStyle = EditorSettings.paragraphStyle(for: font)
        return font
    }
}
