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
                // One flat ForEach with unique ids: nested per-file ForEach keyed by offset left
                // LazyVStack rows blank or misplaced once files had many results.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .file(let file, let isCollapsed):
                            FileResultRow(file: file, isCollapsed: isCollapsed) {
                                if isCollapsed {
                                    search.collapsed.remove(file.id)
                                } else {
                                    search.collapsed.insert(file.id)
                                }
                            }
                        case .match(let file, let line, let range, _):
                            MatchRow(line: line, range: range) {
                                workspace.openFile(file.url, reveal: (line.line, range))
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

    /// VS Code's tree: each file followed, unless collapsed, by one row per match.
    private var rows: [ResultRow] {
        let search = workspace.search
        var rows: [ResultRow] = []
        for file in search.results {
            let isCollapsed = search.collapsed.contains(file.id)
            rows.append(.file(file, isCollapsed: isCollapsed))
            guard !isCollapsed else { continue }
            var index = 0
            for line in file.matches {
                for range in line.ranges {
                    rows.append(.match(file, line, range, index: index))
                    index += 1
                }
            }
        }
        return rows
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

private enum ResultRow: Identifiable {
    case file(SearchModel.FileResult, isCollapsed: Bool)
    /// `index` numbers the file's matches, keeping ids unique across the whole list.
    case match(SearchModel.FileResult, LineMatch, NSRange, index: Int)

    var id: String {
        switch self {
        case .file(let file, _): "file:" + file.id
        case .match(let file, _, _, let index): "match:\(index):" + file.id
        }
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
            FileNameLabel(name: file.url.lastPathComponent, folder: (file.relativePath as NSString).deletingLastPathComponent)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text("\(file.matchCount)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .frame(minHeight: 15)
                .background(Capsule().fill(Theme.UI.listActive))
                .fixedSize()
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
    let line: LineMatch
    let range: NSRange
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
            .help("Line \(line.line + 1)")
    }

    /// The line around this row's match, with only that match highlighted.
    private var preview: AttributedString {
        let preview = TextSearch.preview(of: line.text, match: range)
        let ns = preview.text as NSString
        var result = AttributedString(ns.substring(to: preview.match.location))
        var hit = AttributedString(ns.substring(with: preview.match))
        hit.backgroundColor = Color(nsColor: Theme.searchMatch)
        hit.foregroundColor = Theme.UI.foreground
        result += hit
        result += AttributedString(ns.substring(from: NSMaxRange(preview.match)))
        return result
    }
}
