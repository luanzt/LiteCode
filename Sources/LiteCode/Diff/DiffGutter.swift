import AppKit

/// Strip between the diff panes with VS Code's per-block buttons beside each change: revert
/// (→) and stage (+) in a working-tree diff, unstage (−) in an index diff.
@MainActor
final class DiffActionGutter: NSView {
    static let width: CGFloat = 24

    weak var document: DiffDocument?
    private var hovered: Cell?
    private var trackingArea: NSTrackingArea?

    private struct Cell: Equatable {
        var hunk: Int
        var action: DiffDocument.HunkAction
        var rect: NSRect
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Views no longer clip by default, and the dirty rect may reach past the bounds: an
        // unclipped background fill would paint over the panes and the tab bar.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func cells() -> [Cell] {
        guard let document, document.hunkCount > 0 else { return [] }
        let textView = document.views.right.textView
        let rowHeight = max(18, textView.diffRowHeight)
        var cells: [Cell] = []
        for hunk in 0..<document.hunkCount {
            guard let top = document.hunkTop(hunk) else { continue }
            let y = convert(NSPoint(x: 0, y: top), from: textView).y
            for (offset, action) in document.hunkActions.enumerated() {
                let rect = NSRect(x: 2, y: y + CGFloat(offset) * rowHeight, width: bounds.width - 4, height: rowHeight)
                if rect.intersects(bounds) { cells.append(Cell(hunk: hunk, action: action, rect: rect)) }
            }
        }
        return cells
    }

    override func draw(_ dirtyRect: NSRect) {
        let dirty = dirtyRect.intersection(bounds)
        Theme.editorBackground.setFill()
        dirty.fill()
        Theme.border.setFill()
        NSRect(x: bounds.maxX - 1, y: dirty.minY, width: 1, height: dirty.height).fill(using: .sourceOver)
        for cell in cells() where cell.rect.intersects(dirty) {
            if cell == hovered {
                Theme.listActive.setFill()
                NSBezierPath(roundedRect: cell.rect, xRadius: 4, yRadius: 4).fill()
            }
            let size: CGFloat = 14
            let icon = NSRect(x: cell.rect.midX - size / 2, y: cell.rect.midY - size / 2, width: size, height: size)
            Self.image(for: cell.action).draw(in: icon)
        }
    }

    private static var images: [DiffDocument.HunkAction: NSImage] = [:]

    /// The Lucide icon in the theme's foreground; template images don't tint in plain AppKit drawing.
    private static func image(for action: DiffDocument.HunkAction) -> NSImage {
        if let image = images[action] { return image }
        let icon: LucideIcon = switch action {
        case .revert: .arrowRight
        case .stage: .plus
        case .unstage: .minus
        }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            icon.nsImage.draw(in: rect)
            Theme.foreground.withAlphaComponent(0.85).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        images[action] = image
        return image
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cell = cells().first { $0.rect.contains(point) }
        guard cell != hovered else { return }
        hovered = cell
        toolTip = cell.map { cell in
            switch cell.action {
            case .revert: "Revert Block"
            case .stage: "Stage Block"
            case .unstage: "Unstage Block"
            }
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cells().first(where: { $0.rect.contains(point) }) else { return }
        document?.perform(cell.action, on: cell.hunk)
    }
}

/// VS Code's overview ruler: where the changes are in the whole file, drawn over the right
/// pane's scroller track (removals on the left half, additions on the right).
@MainActor
final class DiffOverviewRuler: NSView {
    weak var document: DiffDocument?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Purely decorative: clicks and drags belong to the scroller underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let document, let layout = document.layout, !layout.hunks.isEmpty else { return }
        let textView = document.views.right.textView
        let total = max(textView.frame.height, 1)
        let scale = bounds.height / total
        for (index, hunk) in layout.hunks.enumerated() {
            guard let top = document.hunkTop(index) else { continue }
            let y = top * scale
            let height = max(2, CGFloat(hunk.rows.count) * textView.diffRowHeight * scale)
            if !hunk.original.isEmpty {
                Theme.gitDeleted.withAlphaComponent(0.7).setFill()
                NSRect(x: 0, y: y, width: bounds.width / 2, height: height).fill()
            }
            if !hunk.modified.isEmpty {
                Theme.gitAdded.withAlphaComponent(0.7).setFill()
                NSRect(x: bounds.width / 2, y: y, width: bounds.width / 2, height: height).fill()
            }
        }
    }
}
