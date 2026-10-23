import AppKit
import SwiftUI

// VS Code / Cursor scrollbars: flat rectangular sliders in the theme's scrollbarSlider colors,
// hidden until the pointer is over the scrollable area (or it is scrolling).

/// Scroller that draws only a flat knob. Legacy-style so AppKit honors the custom drawing
/// (overlay scrollers render through private layers); `HoverScrollView` floats it over the
/// content and controls its visibility.
final class ThemeScroller: NSScroller {
    private var isKnobHovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// VS Code's default `editor.scrollbar.verticalScrollbarSize`.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        14
    }

    /// Only the knob is painted; the text underneath must show through the rest.
    override var isOpaque: Bool { false }

    func setVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.1 : 0.4
            animator().alphaValue = visible ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        (isKnobHovered ? Theme.scrollbarHover : Theme.scrollbar).setFill()
        knob.fill(using: .sourceOver)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isKnobHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isKnobHovered = false
        needsDisplay = true
    }
}

/// Scroll view whose `ThemeScroller`s float over the content and show while the pointer is
/// inside it, or briefly after a scroll.
final class HoverScrollView: NSScrollView {
    private var isHovering = false
    private var hideWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        verticalScroller = ThemeScroller()
        horizontalScroller = ThemeScroller()
        scrollerStyle = .legacy
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keep the custom-drawn legacy scrollers whatever the system scroll bar preference says.
    override var scrollerStyle: NSScroller.Style {
        get { .legacy }
        set { super.scrollerStyle = .legacy }
    }

    /// Legacy layout reserves strips for the scrollers; extend the clip view under them so the
    /// sliders overlay the text like VS Code's.
    override func tile() {
        super.tile()
        var clip = contentView.frame
        if let scroller = verticalScroller, !scroller.isHidden {
            clip.size.width = bounds.maxX - clip.minX
        }
        if let scroller = horizontalScroller, !scroller.isHidden {
            if isFlipped {
                clip.size.height = bounds.maxY - clip.minY
            } else {
                clip.size.height = clip.maxY - bounds.minY
                clip.origin.y = bounds.minY
            }
        }
        contentView.frame = clip
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        hideWork?.cancel()
        setScrollersVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        setScrollersVisible(false)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard !isHovering else { return }
        setScrollersVisible(true)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setScrollersVisible(false) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func setScrollersVisible(_ visible: Bool) {
        for scroller in [verticalScroller, horizontalScroller] {
            (scroller as? ThemeScroller)?.setVisible(visible)
        }
    }
}

/// SwiftUI vertical scroll view with the same flat slider, shown on hover or while scrolling.
///
/// The package keeps a macOS 14 deployment target: linking against macOS 15 stopped SwiftUI
/// from presenting the main window at launch, so the macOS 15 scroll APIs sit behind
/// an availability check instead.
struct ThemedScrollView<Content: View>: View {
    var indicatorWidth: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 15.0, *) {
            SliderScrollView(indicatorWidth: indicatorWidth) { content }
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(.never)
        }
    }
}

@available(macOS 15.0, *)
private struct SliderScrollView<Content: View>: View {
    let indicatorWidth: CGFloat
    @ViewBuilder var content: Content

    @State private var geometry: ScrollGeometry?
    @State private var position = ScrollPosition()
    @State private var isHovering = false
    @State private var isScrolling = false
    @State private var isKnobHovered = false
    @State private var dragStartOffset: CGFloat?

    var body: some View {
        ScrollView(.vertical) { content }
            // .never, not .hidden: .hidden is ignored when "Show scroll bars: Always" is set.
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, new in geometry = new }
            .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
            .overlay(alignment: .topTrailing) { indicator }
            .onHover { isHovering = $0 }
    }

    @ViewBuilder private var indicator: some View {
        if let geometry, geometry.contentSize.height > geometry.visibleRect.height + 1 {
            GeometryReader { proxy in
                let track = proxy.size.height
                let total = geometry.contentSize.height
                let visible = geometry.visibleRect.height
                let maxOffset = total - visible
                let offset = min(max(geometry.visibleRect.minY, 0), maxOffset)
                let knob = max(24, track * visible / total)
                Rectangle()
                    .fill(isKnobHovered || dragStartOffset != nil ? Theme.UI.scrollbarHover : Theme.UI.scrollbar)
                    .frame(height: knob)
                    .offset(y: (track - knob) * offset / maxOffset)
                    .onHover { isKnobHovered = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let start = dragStartOffset ?? offset
                                dragStartOffset = start
                                let moved = start + drag.translation.height * maxOffset / max(1, track - knob)
                                position.scrollTo(y: min(max(moved, 0), maxOffset))
                            }
                            .onEnded { _ in dragStartOffset = nil })
            }
            .frame(width: indicatorWidth)
            .opacity(isHovering || isScrolling || dragStartOffset != nil ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isHovering || isScrolling)
        }
    }
}
