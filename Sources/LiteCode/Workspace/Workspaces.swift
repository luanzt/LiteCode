import AppKit
import Observation
import SwiftUI

/// The open workspaces shown as tabs in the title bar. Every workspace stays alive while
/// another is active, so tabs, unsaved edits, and terminals survive switching.
@MainActor
@Observable
final class Workspaces {
    static let shared = Workspaces()

    private static let savedKey = "workspaces"
    private static let activeKey = "activeWorkspace"
    /// Single-folder key from before workspaces existed; migrated once.
    private static let legacyFolderKey = "lastFolder"

    private struct Saved: Codable {
        var path: String
        var openFiles: [String]
        var activeFile: String?
    }

    private(set) var all: [Workspace] = []
    private(set) var activeID: Workspace.ID?
    /// Bound to the window's NavigationSplitView, so ⌘L works whatever has keyboard focus
    /// (the split view controller's toggleSidebar: action needs it in the responder chain).
    var sidebarVisibility: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }
    @ObservationIgnored private var isRestoring = false

    private init() {
        // Auto save "onWindowChange" (and "onFocusChange", which includes it): the window or the
        // app losing focus saves every dirty editor, as in VS Code.
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Workspaces.shared.all.forEach { $0.autoSaveAll(on: .onWindowChange) }
                }
            }
        }
    }

    var active: Workspace? { all.first { $0.id == activeID } }

    var dirtyDocuments: [(workspace: Workspace, document: EditorDocument)] {
        all.flatMap { workspace in workspace.dirtyDocuments.map { (workspace, $0) } }
    }

    // MARK: Adding and switching

    func promptAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { add(folder: $0) }
    }

    /// Activates the workspace for `folder`, adding it first if it is not open yet.
    @discardableResult
    func add(folder: URL) -> Workspace {
        let url = folder.canonical
        if let existing = all.first(where: { $0.rootURL == url }) {
            activate(existing)
            return existing
        }
        let workspace = Workspace(folder: url)
        workspace.onTabsChanged = { [weak self] in self?.save() }
        all.append(workspace)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        activate(workspace)
        return workspace
    }

    func activate(_ workspace: Workspace) {
        if activeID != workspace.id {
            // Leaving a workspace takes focus from its editor.
            active?.autoSaveAll(on: .onFocusChange)
        }
        activeID = workspace.id
        save()
    }

    func selectAdjacent(_ offset: Int) {
        guard !all.isEmpty, let active, let index = all.firstIndex(where: { $0.id == active.id }) else { return }
        activate(all[(index + offset + all.count) % all.count])
    }

    /// Activates the workspace at a 1-based title-bar position; positions past the end do nothing.
    func select(position: Int) {
        guard all.indices.contains(position - 1) else { return }
        activate(all[position - 1])
    }

    /// Moves a workspace tab into the slot currently held by `target` (drag to reorder).
    func move(_ id: Workspace.ID, to target: Workspace.ID) {
        guard id != target,
              let from = all.firstIndex(where: { $0.id == id }),
              let to = all.firstIndex(where: { $0.id == target }) else { return }
        all.insert(all.remove(at: from), at: to)
        save()
    }

    /// Removes a workspace from the bar (its folder is untouched) after resolving unsaved edits.
    func close(_ workspace: Workspace) {
        guard workspace.confirmDiscardingOrSaving(workspace.dirtyDocuments),
              let index = all.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspace.shutDown()
        all.remove(at: index)
        if activeID == workspace.id {
            activeID = all.isEmpty ? nil : all[min(index, all.count - 1)].id
        }
        save()
    }

    /// Opens a path from Finder, the Dock, or the command line: a folder becomes (or activates)
    /// a workspace; a file opens in the workspace containing it, else in a new one for its folder.
    func open(path url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            add(folder: url)
            return
        }
        let file = url.canonical
        let owner = all
            .filter { file.path.hasPrefix($0.rootURL.path + "/") }
            .max { $0.rootURL.path.count < $1.rootURL.path.count }
        let workspace = owner ?? add(folder: file.deletingLastPathComponent())
        activate(workspace)
        workspace.openFile(file)
    }

    // MARK: Persistence

    func restore() {
        isRestoring = true
        defer {
            isRestoring = false
            save()
        }
        let defaults = UserDefaults.standard
        var saved = defaults.data(forKey: Self.savedKey)
            .flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        if saved.isEmpty, let legacy = defaults.string(forKey: Self.legacyFolderKey) {
            saved = [Saved(path: legacy, openFiles: [], activeFile: nil)]
        }
        defaults.removeObject(forKey: Self.legacyFolderKey)

        for entry in saved {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            add(folder: URL(fileURLWithPath: entry.path, isDirectory: true))
                .restoreTabs(paths: entry.openFiles, active: entry.activeFile)
        }
        let activePath = defaults.string(forKey: Self.activeKey)
        if let match = all.first(where: { $0.rootURL.path == activePath }) ?? all.first {
            activeID = match.id
        }
    }

    private func save() {
        guard !isRestoring else { return }
        let saved = all.map { Saved(path: $0.rootURL.path, openFiles: $0.openFilePaths, activeFile: $0.activeFilePath) }
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(saved), forKey: Self.savedKey)
        defaults.set(active?.rootURL.path, forKey: Self.activeKey)
    }

    // MARK: App-wide

    /// One prompt covering unsaved files in every workspace. Returns false when the user cancels.
    func confirmQuit() -> Bool {
        let pending = dirtyDocuments
        let owners = Dictionary(pending.map { (ObjectIdentifier($0.document), $0.workspace) }, uniquingKeysWith: { first, _ in first })
        return UnsavedChanges.confirm(pending.map(\.document)) { document in
            owners[ObjectIdentifier(document)]?.save(document) ?? false
        }
    }

    func adjustFontSize(by delta: CGFloat) {
        EditorSettings.fontSize += delta
        refreshEditorFonts()
    }

    /// Re-applies the editor font settings to every open text view.
    func refreshEditorFonts() {
        for workspace in all {
            for tab in workspace.tabs {
                switch tab {
                case .file(let document): document.applyFont()
                case .diff(let document): document.applyFont()
                }
            }
        }
    }
}
