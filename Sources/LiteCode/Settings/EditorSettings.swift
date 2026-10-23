import AppKit
import SwiftUI

/// VS Code's `files.autoSave` modes.
enum AutoSaveMode: String, CaseIterable, Identifiable {
    case off, afterDelay, onFocusChange, onWindowChange

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .off: "An editor with changes is never automatically saved."
        case .afterDelay: "An editor with changes is automatically saved after the configured delay."
        case .onFocusChange: "An editor with changes is automatically saved when the editor loses focus."
        case .onWindowChange: "An editor with changes is automatically saved when the window loses focus."
        }
    }
}

/// User preferences (UserDefaults keys shared with `@AppStorage` in views).
enum EditorSettings {
    static let fontSizeKey = "editorFontSize"
    static let fontFamilyKey = "editorFontFamily"
    static let sidebarFontSizeKey = "sidebarFontSize"
    static let tabFontSizeKey = "tabFontSize"
    static let autoSaveKey = "autoSave"
    static let autoSaveDelayKey = "autoSaveDelay"

    static let defaultFontSize = 13.0
    static let defaultSidebarFontSize = 13.0
    static let defaultTabFontSize = 13.0
    static let fontSizeRange = 9.0...32.0
    static let uiFontSizeRange = 10.0...20.0
    /// Milliseconds, as VS Code's `files.autoSaveDelay` (default 1000).
    static let defaultAutoSaveDelay = 1000.0
    static let autoSaveDelayRange = 100.0...10_000.0

    static var autoSave: AutoSaveMode {
        UserDefaults.standard.string(forKey: autoSaveKey).flatMap(AutoSaveMode.init(rawValue:)) ?? .off
    }

    static var autoSaveDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: autoSaveDelayKey)
        return (stored > 0 ? stored : defaultAutoSaveDelay) / 1000
    }

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: fontSizeKey)
            return stored > 0 ? stored : defaultFontSize
        }
        set {
            let clamped = min(max(newValue, fontSizeRange.lowerBound), fontSizeRange.upperBound)
            UserDefaults.standard.set(Double(clamped), forKey: fontSizeKey)
        }
    }

    /// Editor font family; empty means the system monospaced font (SF Mono).
    static var fontFamily: String {
        get { UserDefaults.standard.string(forKey: fontFamilyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: fontFamilyKey) }
    }

    static var font: NSFont { font(family: fontFamily, size: fontSize) }

    static func font(family: String, size: CGFloat) -> NSFont {
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Installed fixed-pitch families, for the font picker.
    static var monospacedFamilies: [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch || manager.traits(of: font).contains(.fixedPitchFontMask)
        }
    }

    /// Columns per tab character, as VS Code's default `editor.tabSize`.
    static let tabWidth = 4

    static func spaceWidth(_ font: NSFont) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    /// Tab stops every `tabWidth` columns (AppKit's default is every 28 points).
    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = spaceWidth(font) * CGFloat(tabWidth)
        return style
    }

    /// Height of the editor tab bar and the sidebar's icon row, which share one strip.
    static func topStripHeight(tabFontSize: Double) -> CGFloat {
        max(34, tabFontSize + 21)
    }
}
