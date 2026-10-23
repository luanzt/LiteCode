import AppKit
import SwiftUI

/// VS Code's Quick Open box, dropped from the top of the window over the editor.
struct QuickOpenView: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    private static let visibleRows = 12

    var body: some View {
        let model = workspace.quickOpen
        let rowHeight = sidebarRowHeight(fontSize) + 4
        ZStack(alignment: .top) {
            // A click anywhere else dismisses it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { workspace.cancelQuickOpen() }
            VStack(spacing: 4) {
                QuickOpenField(
                    text: Bindable(model).query,
                    placeholder: "Search files by name",
                    focusRequest: model.focusRequest,
                    onMove: model.moveSelection,
                    onSubmit: workspace.openQuickOpenSelection,
                    onCancel: workspace.cancelQuickOpen)
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: NSColor(hex: "#F0F0F00A"))))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.UI.accent.opacity(0.7), lineWidth: 1))
                if model.items.isEmpty {
                    if !model.query.isEmpty {
                        Text("No matching results")
                            .foregroundStyle(Theme.UI.inactiveForeground)
                            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                            .padding(.leading, 10)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                    QuickOpenRow(
                                        item: item,
                                        sectionLabel: label(at: index, in: model.items),
                                        isSelected: index == model.selection,
                                        height: rowHeight)
                                        .onTapGesture {
                                            model.selection = index
                                            workspace.openQuickOpenSelection()
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .frame(height: CGFloat(min(model.items.count, Self.visibleRows)) * rowHeight)
                        .onChange(of: model.selection) {
                            if let item = model.selectedItem { proxy.scrollTo(item.id, anchor: nil) }
                        }
                    }
                }
            }
            .font(.system(size: fontSize))
            .padding(6)
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.UI.chromeBackground)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.UI.border, lineWidth: 1))
            .padding(.top, 6)
        }
    }

    /// VS Code labels the first row of each section.
    private func label(at index: Int, in items: [QuickOpenModel.Item]) -> String? {
        let item = items[index]
        guard index == 0 || items[index - 1].isRecent != item.isRecent else { return nil }
        return item.isRecent ? "recently opened" : "file results"
    }
}

private struct QuickOpenRow: View {
    let item: QuickOpenModel.Item
    let sectionLabel: String?
    let isSelected: Bool
    let height: CGFloat
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: item.name)
            Text(highlighted(item.name, offset: item.nameStart)).lineLimit(1)
            Text(highlighted(item.directory, offset: 0))
                .foregroundStyle(Theme.UI.inactiveForeground)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if let sectionLabel {
                Text(sectionLabel).foregroundStyle(Theme.UI.inactiveForeground)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(isSelected ? Theme.UI.listActive : (isHovered ? Theme.UI.listHover : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    /// `text` is `item.path`'s substring starting at UTF-16 `offset`; matched characters get
    /// list.highlightForeground.
    private func highlighted(_ text: String, offset: Int) -> AttributedString {
        var result = AttributedString(text)
        let length = text.utf16.count
        for index in item.highlights where index >= offset && index < offset + length {
            let start = String.Index(utf16Offset: index - offset, in: text)
            let end = String.Index(utf16Offset: index - offset + 1, in: text)
            guard let lower = AttributedString.Index(start, within: result),
                  let upper = AttributedString.Index(end, within: result) else { continue }
            result[lower..<upper].foregroundColor = Theme.UI.accent
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }
}

/// AppKit text field: its delegate sees ↑ ↓ ↩ and Esc as commands before the field editor acts
/// on them, which SwiftUI's TextField doesn't reliably expose.
private struct QuickOpenField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Theme.foreground
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.inactiveForeground, .font: NSFont.systemFont(ofSize: 13),
        ])
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenField
        var focusedRequest = -1

        init(parent: QuickOpenField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
