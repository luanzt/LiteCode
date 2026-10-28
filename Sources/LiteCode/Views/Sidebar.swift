import LiteCodeCore
import SwiftUI

struct Sidebar: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize
    @AppStorage(EditorSettings.tabFontSizeKey) private var tabFontSize = EditorSettings.defaultTabFontSize

    var body: some View {
        VStack(spacing: 0) {
            // Cursor-style activity row: centered icons, the selected one on a rounded tile. Its
            // height matches the editor tab bar so both read as one strip.
            HStack(spacing: 4) {
                SidebarModeTile(mode: .explorer, icon: .files, help: "Explorer (⇧⌘E)")
                SidebarModeTile(mode: .search, icon: .search, help: "Search (⇧⌘F)")
                SidebarModeTile(mode: .changes, icon: .gitBranch, help: "Source Control (⌃⌘G)",
                                badge: workspace.changes.count)
            }
            .frame(maxWidth: .infinity)
            .frame(height: EditorSettings.topStripHeight(tabFontSize: tabFontSize))

            Group {
                switch workspace.sidebarMode {
                case .explorer: ExplorerView()
                case .search: SearchView()
                case .changes: ChangesView()
                }
            }
            // Fresh scroll position and hover state per workspace.
            .id(workspace.id)
        }
        .font(.system(size: fontSize))
        .foregroundStyle(Theme.UI.sidebarForeground)
        .background(Theme.UI.chromeBackground)
    }
}

/// Row height for sidebar lists at the configured sidebar font size.
func sidebarRowHeight(_ fontSize: Double) -> CGFloat { fontSize + 9 }

/// A file name followed by its folder, as VS Code's lists show them: one line truncated at its
/// end, so the folder gives way first and only once it is gone does the name itself truncate.
/// (Two side-by-side Texts each kept a sliver and an ellipsis instead.)
struct FileNameLabel: View {
    let name: String
    let folder: String
    var isStruck = false

    var body: some View {
        (Text(name).strikethrough(isStruck)
            + Text(folder.isEmpty ? "" : "  " + folder).foregroundStyle(Theme.UI.inactiveForeground))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct SidebarModeTile: View {
    @Environment(Workspace.self) private var workspace
    let mode: SidebarMode
    let icon: LucideIcon
    let help: String
    var badge = 0
    @State private var isHovered = false

    private var isSelected: Bool { workspace.sidebarMode == mode }

    var body: some View {
        Button { workspace.sidebarMode = mode } label: {
            LucideImage(icon, size: 16)
                .foregroundStyle(isSelected || isHovered ? Theme.UI.foreground : Theme.UI.inactiveForeground)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? Theme.UI.listActive : (isHovered ? Theme.UI.listHover : .clear)))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(nsColor: NSColor(hex: "#191c22")))
                            .padding(.horizontal, 3)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(Capsule().fill(Theme.UI.accent))
                            .offset(x: 4, y: -3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Uppercase section title, as VS Code/Cursor label the open folder.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.UI.sidebarForeground)
                .lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

private struct ExplorerView: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let root = workspace.rootNode
        VStack(spacing: 0) {
            SectionHeader(title: root.name) {}
            ScrollViewReader { proxy in
                ThemedScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(root.visibleRows(), id: \.node.id) { row in
                            FileRow(node: row.node, depth: row.depth)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .contextMenu { folderMenu(root.url) }
                // Also on appear: a reveal made while Search or Changes was showing lands now.
                .onChange(of: workspace.revealRequest, initial: true) { scrollToRevealed(proxy) }
            }
        }
    }

    /// Scrolls just enough to show the active file's row (none when it is already visible).
    private func scrollToRevealed(_ proxy: ScrollViewProxy) {
        guard let id = workspace.revealedNodeID else { return }
        // Next turn of the run loop: folders the reveal just expanded must be laid out first.
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: nil) }
    }

    @ViewBuilder private func folderMenu(_ directory: URL) -> some View {
        Button("New File…") { workspace.createItem(in: directory, isDirectory: false) }
        Button("New Folder…") { workspace.createItem(in: directory, isDirectory: true) }
    }
}

/// Full-width list row highlight, as in VS Code lists.
func rowBackground(isActive: Bool, isHovered: Bool) -> Color {
    isActive ? Theme.UI.listActive : (isHovered ? Theme.UI.listHover : .clear)
}

private struct FileRow: View {
    @Environment(Workspace.self) private var workspace
    let node: FileNode
    let depth: Int
    @State private var isHovered = false
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    /// The active tab's file, whether shown in an editor or a diff.
    private var isActive: Bool { !node.isDirectory && workspace.activeTab?.fileURL.path == node.path }

    var body: some View {
        HStack(spacing: 5) {
            LucideImage(node.isExpanded ? .chevronDown : .chevronRight, size: 12)
                .foregroundStyle(Theme.UI.sidebarForeground)
                .opacity(node.isDirectory ? 1 : 0)
            FileIcon(name: node.name, isDirectory: node.isDirectory, isExpanded: node.isExpanded)
            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(statusColor ?? Theme.UI.sidebarForeground)
            Spacer(minLength: 4)
            if let status = workspace.statusByPath[node.path] {
                StatusBadge(status: status)
            } else if node.isDirectory, workspace.changedDirectories.contains(node.path) {
                Circle().fill(Theme.UI.gitModified).frame(width: 5, height: 5)
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .padding(.trailing, 12)
        .frame(height: sidebarRowHeight(fontSize))
        .background(rowBackground(isActive: isActive, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            if node.isDirectory { node.toggle() } else { workspace.openFile(node.url) }
        }
        .contextMenu {
            let directory = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
            Button("New File…") { workspace.createItem(in: directory, isDirectory: false) }
            Button("New Folder…") { workspace.createItem(in: directory, isDirectory: true) }
            Divider()
            Button("Rename…") { workspace.rename(node) }
            Button("Move to Trash") { workspace.moveToTrash(node) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.path, forType: .string)
            }
        }
    }

    private var statusColor: Color? {
        guard let status = workspace.statusByPath[node.path] else { return nil }
        return status == .deleted ? .secondary : status.color
    }
}

/// VS Code's Source Control view: "Merge Changes" (unresolved conflicts) and "Staged Changes",
/// each shown only when non-empty, above "Changes"; every group is collapsible with hover
/// actions on the group and on every file.
private struct ChangesView: View {
    private enum ChangeGroup { case merge, staged, changes }

    @Environment(Workspace.self) private var workspace
    @State private var collapsed: Set<ChangeGroup> = []

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "Source Control") {
                if workspace.repositoryRoot != nil {
                    Button { workspace.refreshGit() } label: { LucideImage(.refreshCw, size: 13) }
                        .buttonStyle(.plain)
                        .help("Refresh")
                }
            }
            if workspace.repositoryRoot == nil {
                placeholder("Not a git repository")
            } else {
                if workspace.changes.isEmpty {
                    placeholder("No changes")
                } else {
                    let merge = workspace.changes.filter { $0.status == .conflicted }
                    let staged = workspace.changes.filter { $0.stage == .staged }
                    let unstaged = workspace.changes.filter { $0.stage == .unstaged && $0.status != .conflicted }
                    ThemedScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !merge.isEmpty { group(.merge, title: "Merge Changes", changes: merge) }
                            if !staged.isEmpty { group(.staged, title: "Staged Changes", changes: staged) }
                            group(.changes, title: "Changes", changes: unstaged)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ group: ChangeGroup, title: String, changes: [GitChange]) -> some View {
        let isCollapsed = collapsed.contains(group)
        ChangeGroupHeader(title: title, count: changes.count, isCollapsed: isCollapsed) {
            if isCollapsed { collapsed.remove(group) } else { collapsed.insert(group) }
        } actions: {
            RowActionButton(icon: .fileDiff, help: "Open Changes") { workspace.openDiffs(changes) }
            switch group {
            case .merge:
                RowActionButton(icon: .plus, help: "Stage All Merge Changes") { workspace.stage(changes) }
            case .staged:
                RowActionButton(icon: .minus, help: "Unstage All Changes") { workspace.unstage(changes) }
            case .changes:
                RowActionButton(icon: .undo2, help: "Discard All Changes") { workspace.discard(changes) }
                RowActionButton(icon: .plus, help: "Stage All Changes") { workspace.stage(changes) }
            }
        }
        if !isCollapsed {
            ForEach(changes) { ChangeRow(change: $0) }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangeGroupHeader<Actions: View>: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void
    @ViewBuilder var actions: Actions
    @State private var isHovered = false
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    var body: some View {
        HStack(spacing: 4) {
            LucideImage(isCollapsed ? .chevronRight : .chevronDown, size: 14)
                .foregroundStyle(Theme.UI.sidebarForeground)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if isHovered { actions }
            // badge.background / badge.foreground.
            Text(verbatim: "\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(nsColor: Theme.chromeBackground))
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(Color(nsColor: Theme.gitUntracked)))
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .frame(height: sidebarRowHeight(fontSize) + 2)
        .background(rowBackground(isActive: false, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
    }
}

private struct ChangeRow: View {
    @Environment(Workspace.self) private var workspace
    let change: GitChange
    @State private var isHovered = false
    @AppStorage(EditorSettings.sidebarFontSizeKey) private var fontSize = EditorSettings.defaultSidebarFontSize

    private var fileURL: URL? { workspace.repositoryRoot?.appendingPathComponent(change.path) }
    private var isActive: Bool {
        workspace.repositoryRoot.map { workspace.activeTabID == EditorTab.diffID(change, root: $0) } ?? false
    }

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: (change.path as NSString).lastPathComponent)
            FileNameLabel(name: (change.path as NSString).lastPathComponent,
                          folder: (change.path as NSString).deletingLastPathComponent,
                          isStruck: change.status == .deleted)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if isHovered { actions.fixedSize() }
            StatusBadge(status: change.status).fixedSize()
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .frame(height: sidebarRowHeight(fontSize))
        // Tree indent guide under the group's chevron.
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.UI.border).frame(width: 1).padding(.leading, 13)
        }
        .background(rowBackground(isActive: isActive, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { workspace.openDiff(change) }
        .contextMenu {
            Button("Open Changes") { workspace.openDiff(change) }
            if change.status != .deleted, let fileURL {
                Button("Open File") { workspace.openFile(fileURL) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            }
            Divider()
            if change.stage == .staged {
                Button("Unstage Changes") { workspace.unstage([change]) }
            } else {
                Button("Stage Changes") { workspace.stage([change]) }
                if change.status != .conflicted {
                    Button("Discard Changes") { workspace.discard([change]) }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if change.status != .deleted, let fileURL {
            RowActionButton(icon: .fileSymlink, help: "Open File") { workspace.openFile(fileURL) }
        }
        if change.stage == .staged {
            RowActionButton(icon: .minus, help: "Unstage Changes") { workspace.unstage([change]) }
        } else {
            if change.status != .conflicted {
                RowActionButton(icon: .undo2, help: "Discard Changes") { workspace.discard([change]) }
            }
            RowActionButton(icon: .plus, help: "Stage Changes") { workspace.stage([change]) }
        }
    }
}

/// Small icon button shown on hover in list rows and group headers.
private struct RowActionButton: View {
    let icon: LucideIcon
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            LucideImage(icon, size: 14)
                .foregroundStyle(Theme.UI.foreground)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(isHovered ? Theme.UI.listActive : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}
