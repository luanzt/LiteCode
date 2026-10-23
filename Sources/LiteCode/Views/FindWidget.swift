import AppKit
import SwiftUI

/// VS Code-style find/replace box pinned to the editor's top-right corner.
struct FindWidget: View {
    @Bindable var find: FindModel
    @State private var isFindFocused = false
    @State private var isReplaceFocused = false

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            // Read-only targets (an index diff) only search.
            WidgetButton(icon: find.showReplace ? .chevronDown : .chevronRight, help: "Toggle Replace") {
                find.showReplace.toggle()
            }
            .opacity(find.canReplace ? 1 : 0)
            .disabled(!find.canReplace)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    InputBox(isFocused: isFindFocused, isInvalid: find.isInvalid) {
                        CommandTextField(
                            text: $find.query, placeholder: "Find", focusRequest: find.focusRequest,
                            selectsAllOnFocus: find.selectsQueryOnFocus,
                            onCommand: { selector in
                                switch selector {
                                case #selector(NSResponder.insertNewline(_:)):
                                    NSEvent.modifierFlags.contains(.shift) ? find.previous() : find.next()
                                case #selector(NSResponder.cancelOperation(_:)):
                                    find.close()
                                default:
                                    return false
                                }
                                return true
                            },
                            onFocusChange: { isFindFocused = $0 })
                        OptionToggle(icon: .caseSensitive, help: "Match Case", isOn: $find.caseSensitive)
                        OptionToggle(icon: .wholeWord, help: "Match Whole Word", isOn: $find.wholeWord)
                        OptionToggle(icon: .regex, help: "Use Regular Expression", isOn: $find.regex)
                    }
                    Text(find.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(find.currentIndex == nil && !find.query.isEmpty
                            ? Theme.UI.gitDeleted : Theme.UI.sidebarForeground)
                        .lineLimit(1)
                        .frame(width: 76, alignment: .leading)
                        .padding(.leading, 4)
                    WidgetButton(icon: .arrowUp, help: "Previous Match (⇧↩)", action: find.previous)
                        .disabled(find.matches.isEmpty)
                    WidgetButton(icon: .arrowDown, help: "Next Match (↩)", action: find.next)
                        .disabled(find.matches.isEmpty)
                    WidgetButton(icon: .x, help: "Close (Esc)", action: find.close)
                }
                if find.showReplace && find.canReplace {
                    HStack(spacing: 2) {
                        InputBox(isFocused: isReplaceFocused, isInvalid: false) {
                            CommandTextField(
                                text: $find.replacement, placeholder: "Replace", focusRequest: 0,
                                onCommand: { selector in
                                    switch selector {
                                    case #selector(NSResponder.insertNewline(_:)): find.replaceCurrent()
                                    case #selector(NSResponder.cancelOperation(_:)): find.close()
                                    default: return false
                                    }
                                    return true
                                },
                                onFocusChange: { isReplaceFocused = $0 })
                        }
                        WidgetButton(icon: .replace, help: "Replace (↩)", action: find.replaceCurrent)
                            .disabled(find.currentIndex == nil)
                        WidgetButton(icon: .replaceAll, help: "Replace All", action: find.replaceAll)
                            .disabled(find.matches.isEmpty)
                    }
                }
            }
        }
        .padding(4)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
            .fill(Theme.UI.chromeBackground)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 2))
        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
            .strokeBorder(Theme.UI.border, lineWidth: 1))
    }
}

/// input.background box with focus / validation borders.
private struct InputBox<Content: View>: View {
    let isFocused: Bool
    let isInvalid: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 1) { content }
            .font(.system(size: 13))
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .frame(width: 250, height: 26)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: NSColor(hex: "#F0F0F00A"))))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                isInvalid ? Theme.UI.gitDeleted : (isFocused ? Theme.UI.accent.opacity(0.7) : Theme.UI.border),
                lineWidth: 1))
    }
}

private struct WidgetButton: View {
    let icon: LucideIcon
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LucideImage(icon, size: 15)
                .foregroundStyle(isEnabled ? Theme.UI.foreground : Theme.UI.inactiveForeground)
                .frame(width: 24, height: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(isHovered && isEnabled ? Theme.UI.listHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
