import AppKit
import SwiftUI

/// Icons from Lucide (https://lucide.dev, ISC License), embedded as their original SVG
/// markup. AppKit renders SVG natively; template mode lets SwiftUI tint the strokes.
enum LucideIcon: String {
    case files
    case gitBranch = "git-branch"
    case x
    case chevronRight = "chevron-right"
    case chevronDown = "chevron-down"
    case plus
    case squareTerminal = "square-terminal"
    case refreshCw = "refresh-cw"
    case search
    case caseSensitive = "case-sensitive"
    case regex
    case wholeWord = "whole-word"
    case arrowUp = "arrow-up"
    case arrowDown = "arrow-down"
    case replace
    case replaceAll = "replace-all"
    case fileSymlink = "file-symlink"
    case undo2 = "undo-2"
    case minus
    case fileDiff = "file-diff"
    case arrowRight = "arrow-right"

    private var markup: String {
        switch self {
        case .files:
            """
            <path d="M15 2h-4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V8" />
            <path d="M16.706 2.706A2.4 2.4 0 0 0 15 2v5a1 1 0 0 0 1 1h5a2.4 2.4 0 0 0-.706-1.706z" />
            <path d="M5 7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 1.732-1" />
            """
        case .gitBranch:
            """
            <path d="M15 6a9 9 0 0 0-9 9V3" />
            <circle cx="18" cy="6" r="3" />
            <circle cx="6" cy="18" r="3" />
            """
        case .x:
            """
            <path d="M18 6 6 18" />
            <path d="m6 6 12 12" />
            """
        case .chevronRight:
            #"<path d="m9 18 6-6-6-6" />"#
        case .chevronDown:
            #"<path d="m6 9 6 6 6-6" />"#
        case .plus:
            """
            <path d="M5 12h14" />
            <path d="M12 5v14" />
            """
        case .squareTerminal:
            """
            <path d="m7 11 2-2-2-2" />
            <path d="M11 13h4" />
            <rect width="18" height="18" x="3" y="3" rx="2" ry="2" />
            """
        case .refreshCw:
            """
            <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8" />
            <path d="M21 3v5h-5" />
            <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16" />
            <path d="M8 16H3v5" />
            """
        case .search:
            """
            <path d="m21 21-4.34-4.34" />
            <circle cx="11" cy="11" r="8" />
            """
        case .caseSensitive:
            """
            <path d="m2 16 4.039-9.69a.5.5 0 0 1 .923 0L11 16" />
            <path d="M22 9v7" />
            <path d="M3.304 13h6.392" />
            <circle cx="18.5" cy="12.5" r="3.5" />
            """
        case .regex:
            """
            <path d="M17 3v10" />
            <path d="m12.67 5.5 8.66 5" />
            <path d="m12.67 10.5 8.66-5" />
            <path d="M9 17a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v2a2 2 0 0 0 2 2h2a2 2 0 0 0 2-2v-2z" />
            """
        case .wholeWord:
            """
            <circle cx="7" cy="12" r="3" />
            <path d="M10 9v6" />
            <circle cx="17" cy="12" r="3" />
            <path d="M14 7v8" />
            <path d="M22 17v1c0 .5-.5 1-1 1H3c-.5 0-1-.5-1-1v-1" />
            """
        case .arrowUp:
            """
            <path d="m5 12 7-7 7 7" />
            <path d="M12 19V5" />
            """
        case .arrowDown:
            """
            <path d="M12 5v14" />
            <path d="m19 12-7 7-7-7" />
            """
        case .replace:
            """
            <path d="M14 4a1 1 0 0 1 1-1" />
            <path d="M15 10a1 1 0 0 1-1-1" />
            <path d="M21 4a1 1 0 0 0-1-1" />
            <path d="M21 9a1 1 0 0 1-1 1" />
            <path d="m3 7 3 3 3-3" />
            <path d="M6 10V5a2 2 0 0 1 2-2h2" />
            <rect x="3" y="14" width="7" height="7" rx="1" />
            """
        case .replaceAll:
            """
            <path d="M14 14a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1" />
            <path d="M14 4a1 1 0 0 1 1-1" />
            <path d="M15 10a1 1 0 0 1-1-1" />
            <path d="M19 14a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1" />
            <path d="M21 4a1 1 0 0 0-1-1" />
            <path d="M21 9a1 1 0 0 1-1 1" />
            <path d="m3 7 3 3 3-3" />
            <path d="M6 10V5a2 2 0 0 1 2-2h2" />
            <rect x="3" y="14" width="7" height="7" rx="1" />
            """
        case .fileSymlink:
            """
            <path d="M4 11V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.706.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h7" />
            <path d="M14 2v5a1 1 0 0 0 1 1h5" />
            <path d="m10 18 3-3-3-3" />
            """
        case .undo2:
            """
            <path d="M9 14 4 9l5-5" />
            <path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11" />
            """
        case .minus:
            #"<path d="M5 12h14" />"#
        case .fileDiff:
            """
            <path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z" />
            <path d="M9 10h6" />
            <path d="M12 13V7" />
            <path d="M9 17h6" />
            """
        case .arrowRight:
            """
            <path d="M5 12h14" />
            <path d="m12 5 7 7-7 7" />
            """
        }
    }

    @MainActor private static var cache: [LucideIcon: NSImage] = [:]

    @MainActor var nsImage: NSImage {
        if let image = Self.cache[self] { return image }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" \
            stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(markup)</svg>
            """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        Self.cache[self] = image
        return image
    }
}

extension Image {
    @MainActor init(lucide icon: LucideIcon) {
        self.init(nsImage: icon.nsImage)
    }
}

/// A tinted Lucide icon at a fixed point size.
struct LucideImage: View {
    let icon: LucideIcon
    let size: CGFloat

    init(_ icon: LucideIcon, size: CGFloat = 16) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(lucide: icon)
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
    }
}