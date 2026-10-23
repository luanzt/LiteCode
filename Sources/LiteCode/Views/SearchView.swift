import LiteCodeCore
import SwiftUI

/// Sidebar search across the workspace (⇧⌘F), grouped by file like VS Code's search view.
struct SearchView: View {
    @Environment(Workspace.self) private var workspace
    @State private var isFieldFocused = false

    var body: some View {
        @Bindable var search = workspace.search
        VStack(spacing: 0) {
            SectionHeader(title: "Search") {}
            HStack(spacing: 6) {
                LucideImage(.search, size: 13).foregroundStyle(Theme.UI.inactiveForeground)
                // Focuses on appear and on every ⇧⌘F (searchFocusRequest).
                CommandTextField(
                    text: $search.query, placeholder: "Search", focusRequest: workspace.searchFocusRequest,
                    selectsAllOnFocus: workspace.searchFocusSelectsAll,
                    onCommand: { selector in
                        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
                        runSearch()
                        return true
                    },
                    onFocusChange: { isFieldFocused = $0 })
                OptionToggle(icon: .caseSensitive, help: "Match Case", isOn: $search.caseSensitive)
                OptionToggle(icon: .wholeWord, help: "Match Whole Word", isOn: $search.wholeWord)
                OptionToggle(icon: .regex, help: "Use Regular Expression", isOn: $search.regex)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: NSColor(hex: "#F0F0F00A"))))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                isFieldFocused ? Theme.UI.accent.opacity(0.7) : Theme.UI.border, lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            summary
                .font(.system(size: 11))
                .foregroundStyle(search.errorMessage == nil ? Theme.UI.inactiveForeground : Color(nsColor: Theme.gitDeleted))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            ThemedScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { file in
                        FileResultRow(file: file, isCollapsed: search.collapsed.contains(file.id)) {
                            if search.collapsed.contains(file.id) {
                                search.collapsed.remove(file.id)
                            } else {
                                search.collapsed.insert(file.id)
                            }
                        }
                        if !search.collapsed.contains(file.id) {
                            ForEach(Array(file.matches.enumerated()), id: \.offset) { _, match in
                                MatchRow(match: match) {
                                    workspace.openFile(file.url, reveal: (match.line, match.ranges[0]))
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if !search.query.isEmpty { runSearch() }
        }
        .onChange(of: search.query) { runSearch() }
        .onChange(of: search.caseSensitive) { runSearch() }
        .onChange(of: search.wholeWord) { runSearch() }
        .onChange(of: search.regex) { runSearch() }
    }

    @ViewBuilder private var summary: some View {
        let search = workspace.search
        if let error = search.errorMessage {
            Text(error)
        } else if search.isSearching {
            Text("Searching…")
        } else if !search.query.isEmpty {
            let files = search.results.count
            Text(search.results.isEmpty
                 ? "No results"
                 : "\(search.totalMatches) result\(search.totalMatches == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")\(search.truncated ? " (limit reached)" : "")")
        }
    }

    private func runSearch() {
        workspace.search.schedule(root: workspace.rootURL, repositoryRoot: workspace.repositoryRoot)
    }
}

struct OptionToggle: View {
    let icon: LucideIcon
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            LucideImage(icon, size: 14)
                .foregroundStyle(isOn ? Theme.UI.foreground : Theme.UI.inactiveForeground)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Theme.UI.accent.opacity(0.35) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FileResultRow: View {
    let file: SearchModel.FileResult
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var isHovered = false
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    var body: some View {
        HStack(spacing: 5) {
            LucideImage(isCollapsed ? .chevronRight : .chevronDown, size: 12)
            FileIcon(name: file.url.lastPathComponent)
            Text(file.url.lastPathComponent).lineLimit(1)
            Text((file.relativePath as NSString).deletingLastPathComponent)
                .foregroundStyle(Theme.UI.inactiveForeground)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text("\(file.matchCount)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minHeight: 15)
                .background(Capsule().fill(Theme.UI.listActive))
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: sidebarRowHeight(fontSize))
        .background(rowBackground(isActive: false, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
    }
}

private struct MatchRow: View {
    let match: LineMatch
    let open: () -> Void
    @State private var isHovered = false
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    var body: some View {
        Text(preview)
            .lineLimit(1)
            .padding(.leading, 40)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: sidebarRowHeight(fontSize))
            .background(rowBackground(isActive: false, isHovered: isHovered))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: open)
            .help("Line \(match.line + 1)")
    }

    /// The line with leading whitespace trimmed and every match highlighted; long prefixes are
    /// elided so the first match stays visible.
    private var preview: AttributedString {
        let ns = match.text as NSString
        var start = min(leadingWhitespace(ns), match.ranges.first?.location ?? 0)
        var elided = false
        if let first = match.ranges.first, first.location - start > 40 {
            start = first.location - 20
            elided = true
        }
        var result = AttributedString(elided ? "…" : "")
        var cursor = start
        for range in match.ranges where range.location >= cursor {
            result += AttributedString(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            var hit = AttributedString(ns.substring(with: range))
            hit.backgroundColor = Color(nsColor: Theme.searchMatch)
            hit.foregroundColor = Theme.UI.foreground
            result += hit
            cursor = NSMaxRange(range)
        }
        result += AttributedString(ns.substring(from: min(cursor, ns.length)))
        return result
    }

    private func leadingWhitespace(_ ns: NSString) -> Int {
        var index = 0
        while index < ns.length, let scalar = Unicode.Scalar(ns.character(at: index)),
              CharacterSet.whitespaces.contains(scalar) {
            index += 1
        }
        return index
    }
}
