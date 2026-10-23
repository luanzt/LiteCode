import SwiftUI

struct ContentView: View {
    @Environment(Workspaces.self) private var workspaces

    var body: some View {
        Group {
            if let workspace = workspaces.active {
                WorkspaceView().environment(workspace)
            } else {
                NoWorkspaceView()
            }
        }
        .navigationTitle(workspaces.active?.name ?? "LiteCode")
        .modifier(WindowToolbar())
        // titleBar.activeBackground / foreground, with the theme's text color and button accent.
        .toolbarBackground(Theme.UI.chromeBackground, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .foregroundStyle(Theme.UI.foreground)
        .tint(Theme.UI.accent)
        .preferredColorScheme(.dark)
    }
}

/// The window body for the active workspace; swapping the environment object switches repos.
private struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Workspaces.self) private var workspaces
    @AppStorage("terminalHeight") private var terminalHeight = 240.0
    @State private var dragStartHeight: Double?

    var body: some View {
        // The status bar spans the whole window, under the sidebar too, as in Cursor.
        VStack(spacing: 0) {
            // titleBar.border: separates the title bar from the sidebar and tab strip.
            ThemeDivider()
            NavigationSplitView(columnVisibility: Bindable(workspaces).sidebarVisibility) {
                Sidebar()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 500)
            } detail: {
                VStack(spacing: 0) {
                    EditorArea()
                        .frame(minHeight: 120)
                    if workspace.isTerminalVisible {
                        resizeHandle
                        TerminalPanel()
                            .frame(height: terminalHeight)
                    }
                }
            }
            StatusBar()
        }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Theme.UI.border)
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? terminalHeight
                        dragStartHeight = start
                        terminalHeight = min(max(start - value.translation.height, 80), 900)
                    }
                    .onEnded { _ in dragStartHeight = nil })
    }
}

private struct NoWorkspaceView: View {
    @Environment(Workspaces.self) private var workspaces

    var body: some View {
        VStack(spacing: 0) {
            ThemeDivider()
            VStack(spacing: 14) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("No workspace open").foregroundStyle(.secondary)
                Button("Open Folder…") { workspaces.promptAdd() }
                    .buttonStyle(ThemeButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.UI.editorBackground)
        }
    }
}

/// Title bar: workspace tabs where the title would be (terminal toggle lives in the status bar).
private struct WindowToolbar: ViewModifier {
    func body(content: Content) -> some View {
        let content = content.toolbar {
            ToolbarItem(placement: .navigation) {
                WorkspaceTabStrip()
            }
        }
        // The folder name now lives in the workspace tabs; drop the duplicate title text.
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

private struct StatusBar: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: 14) {
            if let branch = workspace.branch {
                Button { workspace.sidebarMode = .changes } label: {
                    HStack(spacing: 4) {
                        LucideImage(.gitBranch, size: 12)
                        Text(branch)
                        if !workspace.changes.isEmpty { Text("· \(workspace.changes.count)") }
                    }
                }
                .buttonStyle(.plain)
                .help("Source Control (⌃⌘G)")
            }
            Text(workspace.name)
            Spacer()
            if let editor = workspace.activeEditor {
                // verbatim: interpolated Ints in a localized Text get grouping ("Ln 1.272").
                Text(verbatim: "Ln \(editor.cursorLine), Col \(editor.cursorColumn)")
                Text(editor.indentUnit == "\t" ? "Tab Size: \(EditorSettings.tabWidth)" : "Spaces: \(editor.indentUnit.count)")
                Text("UTF-8")
                Text(editor.language.name)
            }
            Button { workspace.toggleTerminal() } label: { LucideImage(.squareTerminal, size: 13) }
                .buttonStyle(.plain)
                .help("Toggle Terminal (⌘B)")
        }
        .lineLimit(1)
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.UI.statusForeground)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.UI.chromeBackground)
        .overlay(alignment: .top) { ThemeDivider() }
    }
}
