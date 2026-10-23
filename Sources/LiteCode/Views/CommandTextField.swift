import AppKit
import SwiftUI

/// Single-line AppKit text field for the find widget and Quick Open. Its delegate sees ↩ ↑ ↓ Esc
/// as commands before the field editor acts on them, and focus requests select the field's own
/// text: SwiftUI's `@FocusState` ignores a request for a field it already believes focused, and a
/// nil-targeted `selectAll:` then landed on the editor, selecting the whole file.
struct CommandTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Each change focuses the field: with `selectsAllOnFocus` its text is selected so typing
    /// replaces it, otherwise the caret goes to the end (a query just filled from the editor's
    /// selection, ready to extend).
    let focusRequest: Int
    var selectsAllOnFocus = true
    /// Handles a field-editor command (`insertNewline:`, `moveUp:`, `cancelOperation:`, …);
    /// returns true when consumed.
    var onCommand: (Selector) -> Bool = { _ in false }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = Theme.foreground
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: Theme.inactiveForeground, .font: NSFont.systemFont(ofSize: 13),
        ])
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Also while editing: a query seeded from the editor selection must replace what's shown.
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusedRequest != focusRequest {
            context.coordinator.focusedRequest = focusRequest
            let selectAll = selectsAllOnFocus
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if field.currentEditor() == nil { window.makeFirstResponder(field) }
                guard let editor = field.currentEditor() else { return }
                if selectAll {
                    editor.selectAll(nil)
                } else {
                    editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandTextField
        var focusedRequest = -1

        init(parent: CommandTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func controlTextDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            parent.onCommand(selector)
        }
    }
}
