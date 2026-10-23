import AppKit
import SwiftTerm
import SwiftUI

/// Oh My Dark (luanzt.oh-my-dark): Cursor Dark chrome with Dracula Soft syntax colors.
/// Values are copied from the extension's themes/oh-my-dark-color-theme.json; the VS Code
/// key each one comes from is noted alongside.
enum Theme {
    // MARK: Editor

    static let editorBackground = NSColor(hex: "#181818")      // editor.background
    static let editorForeground = NSColor(hex: "#F0F0F0")      // editor.foreground
    static let lineHighlight = NSColor(hex: "#262626")         // editor.lineHighlightBackground
    static let selection = NSColor(hex: "#40404099")           // editor.selectionBackground
    static let cursor = NSColor(hex: "#F0F0F0")                // editorCursor.foreground
    static let lineNumber = NSColor(hex: "#F0F0F05C")          // editorLineNumber.foreground
    static let lineNumberActive = NSColor(hex: "#F0F0F0")      // editorLineNumber.activeForeground
    static let indentGuide = NSColor(hex: "#F0F0F013")         // editorIndentGuide.background1
    static let indentGuideActive = NSColor(hex: "#F0F0F030")   // editorIndentGuide.activeBackground1
    static let gutterAdded = NSColor(hex: "#3FA266")           // editorGutter.addedBackground
    static let gutterModified = NSColor(hex: "#D2943E")        // editorGutter.modifiedBackground
    static let gutterDeleted = NSColor(hex: "#E34671")         // editorGutter.deletedBackground
    static let searchMatch = NSColor(hex: "#88C0D044")         // editor.findMatchHighlightBackground
    static let findMatch = NSColor(hex: "#88C0D066")           // editor.findMatchBackground

    // MARK: Chrome

    /// sideBar / editorGroupHeader.tabsBackground / panel / statusBar / titleBar background.
    static let chromeBackground = NSColor(hex: "#141414")
    static let border = NSColor(hex: "#F0F0F013")              // sideBar.border, tab.border, panel.border
    static let foreground = NSColor(hex: "#F0F0F0")            // foreground
    static let sidebarForeground = NSColor(hex: "#F0F0F0BD")   // sideBar.foreground
    static let inactiveForeground = NSColor(hex: "#F0F0F05C")  // tab.inactiveForeground
    static let statusForeground = NSColor(hex: "#F0F0F099")    // statusBar.foreground
    static let listActive = NSColor(hex: "#F0F0F01E")          // list.activeSelectionBackground
    static let listHover = NSColor(hex: "#F0F0F011")           // list.hoverBackground
    static let accent = NSColor(hex: "#81A1C1")                // button.background, textLink.foreground
    static let scrollbar = NSColor(hex: "#F0F0F011")           // scrollbarSlider.background
    static let scrollbarHover = NSColor(hex: "#F0F0F01E")      // scrollbarSlider.hoverBackground / activeBackground

    // MARK: Git and diff

    static let gitModified = NSColor(hex: "#F1B467")           // gitDecoration.modifiedResourceForeground
    static let gitAdded = NSColor(hex: "#70B489")              // gitDecoration.addedResourceForeground
    static let gitDeleted = NSColor(hex: "#FC6B83")            // gitDecoration.deletedResourceForeground
    static let gitUntracked = NSColor(hex: "#88C0D0")          // gitDecoration.untrackedResourceForeground
    static let gitConflict = NSColor(hex: "#B48EAD")           // no theme key; terminal.ansiMagenta
    static let diffInserted = NSColor(hex: "#3FA26633")        // diffEditor.insertedLineBackground
    static let diffRemoved = NSColor(hex: "#B8004933")         // diffEditor.removedLineBackground
    static let diffInsertedText = NSColor(hex: "#3FA26655")    // diffEditor.insertedTextBackground
    static let diffRemovedText = NSColor(hex: "#B8004966")     // diffEditor.removedTextBackground
    static let diffFiller = NSColor(hex: "#F0F0F013")          // diffEditor.diagonalFill

    // MARK: Terminal

    static let terminalBackground = NSColor(hex: "#141414")    // terminal.background
    static let terminalForeground = NSColor(hex: "#F0F0F0")    // terminal.foreground
    static let terminalSelection = NSColor(hex: "#F0F0F01E")   // terminal.selectionBackground
    /// terminal.ansiBlack … terminal.ansiBrightWhite, in ANSI order. ansiBrightBlack is
    /// #F0F0F099 in the theme; the palette has no alpha, so it is pre-blended over the background.
    static let terminalANSI: [UInt32] = [
        0x242424, 0xFC6B83, 0x3FA266, 0xD2943E, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xF0F0F0,
        0x989898, 0xFC6B83, 0x70B489, 0xF1B467, 0x87A6C4, 0xB48EAD, 0x88C0D0, 0xFFFFFF,
    ]
}

extension Theme {
    /// SwiftUI counterparts of the chrome colors.
    enum UI {
        static let editorBackground = Color(nsColor: Theme.editorBackground)
        static let chromeBackground = Color(nsColor: Theme.chromeBackground)
        static let border = Color(nsColor: Theme.border)
        static let foreground = Color(nsColor: Theme.foreground)
        static let sidebarForeground = Color(nsColor: Theme.sidebarForeground)
        static let inactiveForeground = Color(nsColor: Theme.inactiveForeground)
        static let statusForeground = Color(nsColor: Theme.statusForeground)
        static let lineNumber = Color(nsColor: Theme.lineNumber)
        static let listActive = Color(nsColor: Theme.listActive)
        static let listHover = Color(nsColor: Theme.listHover)
        static let accent = Color(nsColor: Theme.accent)
        static let scrollbar = Color(nsColor: Theme.scrollbar)
        static let scrollbarHover = Color(nsColor: Theme.scrollbarHover)
        static let diffInserted = Color(nsColor: Theme.diffInserted)
        static let diffRemoved = Color(nsColor: Theme.diffRemoved)
        static let diffFiller = Color(nsColor: Theme.diffFiller)
        static let gitAdded = Color(nsColor: Theme.gitAdded)
        static let gitDeleted = Color(nsColor: Theme.gitDeleted)
        static let gitModified = Color(nsColor: Theme.gitModified)
    }
}

extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA`, as used in VS Code theme files.
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt64(digits, radix: 16) ?? 0
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: hasAlpha ? CGFloat(value & 0xFF) / 255 : 1)
    }
}

/// One-point line in the theme's border color (SwiftUI's Divider ignores tinting).
struct ThemeDivider: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(Theme.UI.border)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
    }
}

/// button.background / button.foreground / button.hoverBackground (shown while pressed).
struct ThemeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Color(nsColor: NSColor(hex: "#191c22")))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: configuration.isPressed ? NSColor(hex: "#87A6C4") : Theme.accent)))
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

extension SwiftTerm.Color {
    convenience init(rgb: UInt32) {
        self.init(
            red: UInt16((rgb >> 16) & 0xFF) * 257,
            green: UInt16((rgb >> 8) & 0xFF) * 257,
            blue: UInt16(rgb & 0xFF) * 257)
    }
}
