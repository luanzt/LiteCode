import AppKit
import Sparkle
import SwiftUI

@main
struct LiteCodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspaces = Workspaces.shared

    private var workspace: Workspace? { workspaces.active }

    /// The editable code view with keyboard focus (an editor or a diff's working-tree side),
    /// else the active editor's.
    private var editingView: CodeTextView? {
        if let focused = NSApp.keyWindow?.firstResponder as? CodeTextView, focused.isEditable { return focused }
        return workspace?.activeEditor?.textView
    }

    var body: some Scene {
        Window("LiteCode", id: "main") {
            ContentView()
                .environment(workspaces)
                .frame(minWidth: 700, minHeight: 420)
        }
        // Slim title bar like Cursor's.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.checkForUpdates() }
                    .disabled(!appDelegate.canCheckForUpdates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { workspaces.promptAdd() }
                    .keyboardShortcut("o")
                Button("New File…") {
                    if let workspace { workspace.createItem(in: workspace.rootURL, isDirectory: false) }
                }
                .keyboardShortcut("n")
                .disabled(workspace == nil)
                Divider()
                Button("Close Workspace") { workspace.map(workspaces.close) }
                    .disabled(workspace == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { workspace?.saveActive() }
                    .keyboardShortcut("s")
                Button("Save All") { workspaces.all.forEach { $0.saveAll() } }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                // ⌘W itself is intercepted in AppDelegate so it beats the window's Close item.
                Button("Close Tab") { workspace?.closeActiveTab() }
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find…") { workspace?.activeFind?.open(replace: false) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { workspace?.activeFind?.open(replace: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { workspace?.activeFind?.next() }
                    .keyboardShortcut("g")
                Button("Find Previous") { workspace?.activeFind?.previous() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Line Comment") { editingView?.toggleLineComment() }
                    .keyboardShortcut("/")
                Button("Indent Lines") { editingView?.indentSelection() }
                    .keyboardShortcut("]")
                Button("Outdent Lines") { editingView?.outdentSelection() }
                    .keyboardShortcut("[")
            }
            // ⌘P belongs to Quick Open, as in VS Code; there is nothing to print.
            CommandGroup(replacing: .printItem) {}
            CommandMenu("Go") {
                Button("Go to File…") { workspace?.showQuickOpen() }
                    .keyboardShortcut("p")
                Divider()
                Button("Next Tab") { workspace?.selectAdjacentTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { workspace?.selectAdjacentTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("Next Workspace") { workspaces.selectAdjacent(1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                Button("Previous Workspace") { workspaces.selectAdjacent(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
            }
            CommandGroup(before: .sidebar) {
                Button("Toggle Sidebar") { workspaces.toggleSidebar() }
                    .keyboardShortcut("l")
                Button("Explorer") { workspace?.sidebarMode = .explorer }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Search") { workspace?.focusSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Source Control Changes") { workspace?.sidebarMode = .changes }
                    .keyboardShortcut("g", modifiers: [.command, .control])
                Button("Refresh Changes") { workspace?.refreshGit() }
                Divider()
                Button("Toggle Terminal") { workspace?.toggleTerminal() }
                    .keyboardShortcut("b")
                Button("New Terminal") { workspace?.newTerminal() }
                    .keyboardShortcut("`", modifiers: [.control, .shift])
                Divider()
                Button("Increase Font Size") { workspaces.adjustFontSize(by: 1) }
                    .keyboardShortcut("=")
                Button("Decrease Font Size") { workspaces.adjustFontSize(by: -1) }
                    .keyboardShortcut("-")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    /// Sparkle, fed by the appcast the release script publishes. Started only in packaged builds:
    /// `swift run` binaries have no SUFeedURL, and starting without one shows an error alert.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var canCheckForUpdates: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Oh My Dark is a dark-only theme; keep alerts, panels, and the find bar dark too.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspaces = Workspaces.shared
        workspaces.restore()
        if canCheckForUpdates { updaterController.startUpdater() }
        for path in CommandLine.arguments.dropFirst() where !path.hasPrefix("-") {
            workspaces.open(path: URL(fileURLWithPath: path))
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers == "w",
                  NSApp.modalWindow == nil, event.window?.attachedSheet == nil,
                  let window = event.window, !(window is NSPanel),
                  let workspace = workspaces.active, workspace.activeTabID != nil else { return event }
            workspace.closeActiveTab()
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { Workspaces.shared.open(path: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Workspaces.shared.confirmQuit() ? .terminateNow : .terminateCancel
    }
}
