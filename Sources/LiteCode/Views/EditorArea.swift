import AppKit
import SwiftUI

struct EditorArea: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            // Always present so it lines up with the sidebar's icon row, as in Cursor.
            TabBar()
            ThemeDivider()
            if let url = workspace.activeTab?.fileURL {
                Breadcrumbs(url: url)
            }
            switch workspace.activeTab {
            case .file(let document):
                if document.isBinary {
                    placeholder("Binary file — not shown")
                } else if let error = document.loadError {
                    placeholder(error)
                } else {
                    EditorContainer(document: document)
                        .overlay(alignment: .topTrailing) {
                            if document.find.isVisible {
                                // Clear of the vertical scrollbar, as in VS Code.
                                FindWidget(find: document.find).padding(.trailing, 16)
                            }
                        }
                }
            case .diff(let document):
                DiffView(document: document)
            case nil:
                WelcomeView()
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.UI.editorBackground)
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                shortcut("Add Workspace", "⌘O")
                shortcut("Next / Previous Workspace", "⌥⌘] / ⌥⌘[")
                shortcut("Go to Workspace 1–9", "⌘1 … ⌘9")
                shortcut("Save", "⌘S")
                shortcut("Close Tab", "⌘W")
                shortcut("Find / Replace", "⌘F / ⌥⌘F")
                shortcut("Toggle Terminal", "⌘B")
                shortcut("Changes", "⌃⌘G")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.UI.editorBackground)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        GridRow {
            Text(title)
            Text(keys).font(.system(.callout, design: .monospaced))
        }
    }
}

private struct TabBar: View {
    @Environment(Workspace.self) private var workspace
    @AppStorage(EditorSettings.tabFontSizeKey) private var fontSize = EditorSettings.defaultTabFontSize

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(workspace.tabs) { tab in
                        TabItem(tab: tab, isActive: tab.id == workspace.activeTabID).id(tab.id)
                        ThemeDivider(axis: .vertical)
                    }
                }
            }
            .onChange(of: workspace.activeTabID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: EditorSettings.topStripHeight(tabFontSize: fontSize))
        .background(Theme.UI.chromeBackground)
    }
}

private struct TabItem: View {
    @Environment(Workspace.self) private var workspace
    let tab: EditorTab
    let isActive: Bool
    @State private var isHovered = false
    @AppStorage(EditorSettings.tabFontSizeKey) private var fontSize = EditorSettings.defaultTabFontSize

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: tab.title)
            Text(tab.title).lineLimit(1)
            if case .diff(let document) = tab {
                // VS Code's labels: staged diffs end at the index, unstaged ones at the working tree.
                Text(document.change.stage == .staged ? "(Index)" : "(Working Tree)").lineLimit(1).opacity(0.7)
            }
            Button { workspace.closeTab(tab.id) } label: {
                Group {
                    if tab.isDirty && !isHovered {
                        Circle().frame(width: 8, height: 8)
                    } else {
                        LucideImage(.x, size: 13)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered || tab.isDirty ? 1 : 0)
        }
        .font(.system(size: fontSize))
        // Cursor Dark tabs: tab.activeForeground / tab.inactiveForeground, and the active tab
        // takes the editor background with no accent border (tab.activeBorderTop is transparent).
        .foregroundStyle(isActive ? Theme.UI.foreground : Theme.UI.inactiveForeground)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .background(isActive ? Theme.UI.editorBackground : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { workspace.activeTabID = tab.id }
        .help(tab.fileURL.path)
    }
}

/// `folder › folder › file` path of the active tab, relative to the open folder.
private struct Breadcrumbs: View {
    @Environment(Workspace.self) private var workspace
    let url: URL

    private var components: [String] {
        let root = workspace.rootURL.path
        guard url.path.hasPrefix(root + "/") else {
            return [url.lastPathComponent]
        }
        return String(url.path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(components.enumerated()), id: \.offset) { index, name in
                if index > 0 {
                    LucideImage(.chevronRight, size: 12).foregroundStyle(Theme.UI.inactiveForeground)
                }
                if index == components.count - 1 {
                    FileIcon(name: name)
                    Text(name).foregroundStyle(Theme.UI.foreground)
                } else {
                    Text(name).foregroundStyle(Theme.UI.sidebarForeground)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Theme.UI.editorBackground)
    }
}

/// Hosts the active document's own scroll view; swapping documents swaps the subview.
struct EditorContainer: NSViewRepresentable {
    let document: EditorDocument

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(in: container)
    }

    private func install(in container: NSView) {
        let scroll = document.scrollView
        guard scroll.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        scroll.frame = container.bounds
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        DispatchQueue.main.async {
            if let textView = document.textView {
                container.window?.makeFirstResponder(textView)
            }
            document.applyPendingReveal()
        }
    }
}
