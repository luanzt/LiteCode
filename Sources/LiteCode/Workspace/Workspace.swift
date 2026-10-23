import AppKit
import LiteCodeCore
import Observation

@MainActor
enum EditorTab: @MainActor Identifiable {
    case file(EditorDocument)
    case diff(DiffDocument)

    var id: String {
        switch self {
        case .file(let document): "file:" + document.url.path
        case .diff(let document): Self.diffID(document.change, root: document.repositoryRoot)
        }
    }

    var title: String {
        switch self {
        case .file(let document): document.name
        case .diff(let document): document.name
        }
    }

    var fileURL: URL {
        switch self {
        case .file(let document): document.url
        case .diff(let document): document.fileURL
        }
    }

    var isDirty: Bool {
        switch self {
        case .file(let document): document.isDirty
        case .diff(let document): document.isDirty
        }
    }

    /// The text document this tab edits: the file itself, or a working-tree diff's right side.
    var textDocument: EditorDocument? {
        switch self {
        case .file(let document): document
        case .diff(let document): document.editable
        }
    }

    /// Staged and unstaged diffs of one file are separate tabs, as in VS Code.
    static func diffID(_ change: GitChange, root: URL) -> String {
        "diff:\(change.stage.rawValue):" + root.appendingPathComponent(change.path).path
    }
}

enum SidebarMode: String {
    case explorer, search, changes
}

/// One open folder: its file tree, editor tabs, git state, and terminals. `Workspaces` keeps
/// several alive at once so switching between them preserves everything.
@MainActor
@Observable
final class Workspace: Identifiable {
    let id = UUID()
    let rootURL: URL
    let rootNode: FileNode
    private(set) var tabs: [EditorTab] = [] {
        didSet { onTabsChanged?() }
    }
    var activeTabID: String? {
        didSet {
            onTabsChanged?()
            guard oldValue != activeTabID else { return }
            // Switching tabs takes focus from the previous editor.
            if case .file(let previous) = tabs.first(where: { $0.id == oldValue }) {
                previous.autoSave(on: .onFocusChange)
            }
            revealActiveFile()
        }
    }
    /// Tree row of the active tab's file, expanded into view (VS Code's explorer.autoReveal).
    /// The explorer scrolls to it whenever `revealRequest` changes, or when it next appears.
    private(set) var revealedNodeID: URL?
    private(set) var revealRequest = 0

    @ObservationIgnored private var isRestoringTabs = false

    private func revealActiveFile() {
        guard !isRestoringTabs, let path = activeTab?.fileURL.path, let node = rootNode.reveal(path: path) else { return }
        revealedNodeID = node.id
        revealRequest += 1
    }

    var sidebarMode: SidebarMode = .explorer

    private(set) var repositoryRoot: URL?
    private(set) var branch: String?
    private(set) var changes: [GitChange] = []
    /// Absolute path → status, for tree decorations.
    private(set) var statusByPath: [String: GitChange.Status] = [:]
    /// Absolute paths of directories containing changes.
    private(set) var changedDirectories: Set<String> = []

    private(set) var terminals: [TerminalSession] = []
    var activeTerminalID: UUID?
    var isTerminalVisible = false
    private var terminalCounter = 0

    /// Lets `Workspaces` persist the open tabs whenever they change.
    @ObservationIgnored var onTabsChanged: (() -> Void)?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var gitRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var gitRefreshPending = false
    @ObservationIgnored private var headCommit: String?
    @ObservationIgnored private var hasLoadedBases = false

    /// Sidebar search across this workspace's files.
    let search = SearchModel()
    /// Bumped to move keyboard focus into the search field (⇧⌘F).
    private(set) var searchFocusRequest = 0

    func focusSearch() {
        sidebarMode = .search
        searchFocusRequest += 1
    }

    var name: String { rootURL.lastPathComponent }

    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }

    var activeEditor: EditorDocument? {
        if case .file(let document) = activeTab { return document }
        return nil
    }

    /// Find state for ⌘F: the editor's, or the diff tab's (searching its right side).
    var activeFind: FindModel? {
        switch activeTab {
        case .file(let document): document.find
        case .diff(let document): document.find
        case nil: nil
        }
    }

    /// Every open text document once, whether shown in a file tab, a diff tab, or both.
    var openDocuments: [EditorDocument] {
        var seen = Set<ObjectIdentifier>()
        return tabs.compactMap(\.textDocument).filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    var dirtyDocuments: [EditorDocument] {
        openDocuments.filter(\.isDirty)
    }

    /// Paths of open file tabs, in tab order (diff tabs are not restored).
    var openFilePaths: [String] {
        tabs.compactMap { if case .file(let document) = $0 { return document.url.path } else { return nil } }
    }

    var activeFilePath: String? { activeEditor?.url.path }

    init(folder: URL) {
        let url = folder.canonical
        rootURL = url
        let node = FileNode(url: url, isDirectory: true)
        node.isExpanded = true
        node.reloadChildren()
        rootNode = node

        watcher = FileWatcher(path: url.path) { [weak self] paths in
            MainActor.assumeIsolated { self?.handleFileEvents(paths) }
        }
        Task {
            repositoryRoot = await Git.repositoryRoot(for: url)
            refreshGit()
        }
    }

    /// Stops background work and the shells, for a workspace being removed.
    func shutDown() {
        terminals.forEach { $0.terminate() }
        terminals = []
        watcher = nil
    }

    /// Reopens file tabs saved from a previous launch, skipping files that no longer exist.
    func restoreTabs(paths: [String], active: String?) {
        // Only the tab that ends up active is revealed; the others would expand their folders too.
        isRestoringTabs = true
        for path in paths where FileManager.default.fileExists(atPath: path) {
            openFile(URL(fileURLWithPath: path))
        }
        if let active, tabs.contains(where: { $0.id == "file:" + active }) {
            activeTabID = "file:" + active
        }
        isRestoringTabs = false
        revealActiveFile()
    }

    private func handleFileEvents(_ paths: [String]) {
        refreshGit()
        let treePaths = paths.filter { !$0.contains("/.git/") && !$0.hasSuffix("/.git") }
        guard !treePaths.isEmpty else { return }
        var touched = Set(treePaths)
        for path in treePaths { touched.insert((path as NSString).deletingLastPathComponent) }
        for directory in rootNode.expandedDirectories() where touched.contains(directory.path) {
            directory.reloadChildren()
        }
        for document in openDocuments where touched.contains(document.url.path) {
            document.reloadIfChangedOnDisk()
        }
    }

    // MARK: Git

    /// Coalesces refresh requests: at most one `git status` runs, plus one queued follow-up.
    func refreshGit() {
        guard repositoryRoot != nil else { return }
        if gitRefreshTask != nil {
            gitRefreshPending = true
            return
        }
        gitRefreshTask = Task { [weak self] in
            await self?.performGitRefresh()
            guard let self else { return }
            self.gitRefreshTask = nil
            if self.gitRefreshPending {
                self.gitRefreshPending = false
                self.refreshGit()
            }
        }
    }

    private func performGitRefresh() async {
        guard let root = repositoryRoot else { return }
        async let statusResult = Git.status(in: root)
        async let branchResult = Git.branch(in: root)
        async let headResult = Git.headCommit(in: root)
        let (status, branchName, head) = await (statusResult, branchResult, headResult)
        guard root == repositoryRoot, let status else { return }
        branch = branchName
        // The gutter compares against the index, so a new HEAD (commit, checkout) or any change in
        // what is staged changes its base.
        if head != headCommit || status != changes || !hasLoadedBases {
            headCommit = head
            hasLoadedBases = true
            for document in openDocuments { loadBase(for: document) }
        }
        if status != changes {
            changes = status
            var byPath: [String: GitChange.Status] = [:]
            var directories = Set<String>()
            for change in status {
                let absolute = root.appendingPathComponent(change.path).path
                // A partly staged file shows its working-tree status, as in VS Code's explorer.
                if change.stage == .unstaged || byPath[absolute] == nil { byPath[absolute] = change.status }
                var parent = (absolute as NSString).deletingLastPathComponent
                while parent.count >= root.path.count, directories.insert(parent).inserted {
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            statusByPath = byPath
            changedDirectories = directories
        }
        for case .diff(let document) in tabs {
            if let change = status.first(where: { $0.id == document.change.id }) {
                document.update(change: change)
            }
            await document.reload()
        }
    }

    // MARK: Staging

    func stage(_ changes: [GitChange]) {
        runGit(changes) { paths, root in await Git.stage(paths, in: root) }
    }

    func unstage(_ changes: [GitChange]) {
        // A staged rename also stages its source's deletion; unstage both halves.
        runGit(changes, includeOriginals: true) { paths, root in await Git.unstage(paths, in: root) }
    }

    /// Reverts working-tree changes after confirmation: tracked files go back to their staged
    /// version, untracked files move to the Trash.
    func discard(_ changes: [GitChange]) {
        let changes = changes.filter { $0.stage == .unstaged && $0.status != .conflicted }
        guard let root = repositoryRoot, !changes.isEmpty, confirmDiscard(changes) else { return }
        let untracked = changes.filter { $0.status == .untracked }
        var failures: [String] = []
        for change in untracked {
            do {
                try FileManager.default.trashItem(at: root.appendingPathComponent(change.path), resultingItemURL: nil)
            } catch {
                failures.append("\(change.path): \(error.localizedDescription)")
            }
        }
        let tracked = changes.filter { $0.status != .untracked }
        guard !tracked.isEmpty else {
            finishGit(errors: failures)
            return
        }
        runGit(tracked, extraErrors: failures) { paths, root in await Git.discard(paths, in: root) }
    }

    private func runGit(_ changes: [GitChange], includeOriginals: Bool = false, extraErrors: [String] = [],
                        _ command: @escaping ([String], URL) async -> Git.Output) {
        guard let root = repositoryRoot, !changes.isEmpty else { return }
        var paths = changes.map(\.path)
        if includeOriginals { paths += changes.compactMap(\.originalPath) }
        Task {
            let output = await command(paths, root)
            let errors = output.ok ? extraErrors : extraErrors + [output.text.trimmingCharacters(in: .whitespacesAndNewlines)]
            finishGit(errors: errors)
        }
    }

    private func finishGit(errors: [String]) {
        refreshGit()
        guard !errors.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Git failed"
        alert.informativeText = errors.joined(separator: "\n")
        alert.runModal()
    }

    private func confirmDiscard(_ changes: [GitChange]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if changes.count == 1 {
            let name = (changes[0].path as NSString).lastPathComponent
            if changes[0].status == .untracked {
                alert.messageText = "Are you sure you want to delete '\(name)'?"
                alert.informativeText = "The file will be moved to the Trash."
            } else {
                alert.messageText = "Are you sure you want to discard changes in '\(name)'?"
                alert.informativeText = "This is irreversible: the working-tree changes will be lost."
            }
        } else {
            alert.messageText = "Are you sure you want to discard all changes in \(changes.count) files?"
            alert.informativeText = "This is irreversible. Untracked files will be moved to the Trash."
        }
        alert.addButton(withTitle: changes.count == 1 && changes[0].status == .untracked ? "Move to Trash" : "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Tabs

    /// Opens (or focuses) a file tab; `reveal` selects a range on a 0-based line.
    func openFile(_ url: URL, reveal: (line: Int, range: NSRange)? = nil) {
        let url = url.canonical
        let id = "file:" + url.path
        if !tabs.contains(where: { $0.id == id }) {
            insertTab(.file(document(for: url)))
        }
        activeTabID = id
        if let reveal, case .file(let document) = activeTab {
            document.reveal(line: reveal.line, range: reveal.range)
        }
    }

    /// The open document for `url` (a working-tree diff may already hold it), or a new one.
    /// One document per file keeps editor and diff tabs editing the same buffer.
    private func document(for url: URL) -> EditorDocument {
        if let open = openDocuments.first(where: { $0.url == url }) { return open }
        let document = EditorDocument(url: url)
        document.autoSaveHandler = { [weak self] in self?.autoSave($0) }
        if hasLoadedBases { loadBase(for: document) }
        return document
    }

    /// Feeds a document the staged (index) version of its file for the gutter's change markers;
    /// files not in the index (untracked) get none.
    private func loadBase(for document: EditorDocument) {
        guard let root = repositoryRoot, document.url.path.hasPrefix(root.path + "/"), !document.isBinary else {
            document.setBase(nil)
            return
        }
        let path = String(document.url.path.dropFirst(root.path.count + 1))
        Task {
            let data = await Git.indexContents(of: path, in: root)
            document.setBase(data.map { String(decoding: $0, as: UTF8.self) })
        }
    }

    func openDiff(_ change: GitChange) {
        guard let root = repositoryRoot else { return }
        let id = EditorTab.diffID(change, root: root)
        if !tabs.contains(where: { $0.id == id }) {
            // A working-tree diff edits the file itself, like VS Code's modified side.
            let editable = change.stage == .unstaged && change.status != .deleted
                ? document(for: root.appendingPathComponent(change.path).canonical)
                : nil
            let document = DiffDocument(change: change, repositoryRoot: root, editable: editable) { [weak self] data, path in
                self?.writeIndex(data, path: path)
            }
            insertTab(.diff(document))
            Task { await document.reload() }
        }
        activeTabID = id
    }

    /// Stages new content for one file (a diff block's stage / unstage).
    private func writeIndex(_ data: Data, path: String) {
        guard let root = repositoryRoot else { return }
        Task {
            let output = await Git.setIndexContents(data, of: path, in: root)
            finishGit(errors: output.ok ? [] : [output.text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    /// Opens a diff tab for each change (the group header's "Open Changes"), focusing the first.
    func openDiffs(_ changes: [GitChange]) {
        guard let first = changes.first else { return }
        // Each tab opens right after the previous one, keeping the group's order.
        changes.forEach(openDiff)
        openDiff(first)
    }

    private func insertTab(_ tab: EditorTab) {
        if let activeTabID, let index = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
    }

    func closeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // Unsaved edits only need a decision when no other tab keeps showing the document.
        if let document = tabs[index].textDocument, document.isDirty,
           !tabs.indices.contains(where: { $0 != index && tabs[$0].textDocument === document }) {
            guard confirmDiscardingOrSaving([document]) else { return }
        }
        if case .diff(let document) = tabs[index] { document.close() }
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeActiveTab() {
        if let activeTabID { closeTab(activeTabID) }
    }

    func selectAdjacentTab(_ offset: Int) {
        guard !tabs.isEmpty else { return }
        let index = tabs.firstIndex { $0.id == activeTabID } ?? 0
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    // MARK: Saving

    @discardableResult
    func save(_ document: EditorDocument) -> Bool {
        do {
            try document.save()
            refreshGit()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func saveActive() {
        if let document = activeTab?.textDocument { save(document) }
    }

    /// Auto save writes quietly: a failure (read-only file, disk full) leaves the tab dirty
    /// instead of interrupting typing with an alert; ⌘S still reports the error.
    private func autoSave(_ document: EditorDocument) {
        guard (try? document.save()) != nil else { return }
        refreshGit()
    }

    /// Window or workspace focus moved away: auto-save every open file that the mode covers.
    func autoSaveAll(on trigger: AutoSaveMode) {
        for document in openDocuments { document.autoSave(on: trigger) }
    }

    func saveAll() {
        dirtyDocuments.forEach { save($0) }
    }

    /// Asks what to do with this workspace's unsaved documents. Returns false when the user cancels.
    func confirmDiscardingOrSaving(_ documents: [EditorDocument]) -> Bool {
        UnsavedChanges.confirm(documents) { save($0) }
    }

    // MARK: File operations

    func createItem(in directory: URL, isDirectory: Bool) {
        guard let name = prompt(isDirectory ? "New Folder" : "New File", defaultValue: "") else { return }
        let url = directory.appendingPathComponent(name)
        do {
            if isDirectory {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
                }
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        expandAndReload(directory)
        if !isDirectory { openFile(url) }
    }

    func rename(_ node: FileNode) {
        guard let name = prompt("Rename", defaultValue: node.name), name != node.name else { return }
        let destination = node.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: node.url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for document in openDocuments where document.url == node.url {
            document.moved(to: destination)
            loadBase(for: document)
        }
        expandAndReload(node.url.deletingLastPathComponent())
    }

    func moveToTrash(_ node: FileNode) {
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        let prefix = node.url.path
        for tab in tabs {
            if case .file(let document) = tab, document.url.path == prefix || document.url.path.hasPrefix(prefix + "/") {
                tabs.removeAll { $0.id == tab.id }
                if activeTabID == tab.id { activeTabID = tabs.last?.id }
            }
        }
        expandAndReload(node.url.deletingLastPathComponent())
    }

    private func expandAndReload(_ directory: URL) {
        let path = directory.canonical.path
        if rootNode.path == path {
            rootNode.reloadChildren()
            return
        }
        for node in rootNode.expandedDirectories() {
            node.reloadChildren()
            if let child = node.children?.first(where: { $0.path == path }) {
                child.isExpanded = true
                child.reloadChildren()
            }
        }
    }

    private func prompt(_ title: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: Terminal

    func toggleTerminal() {
        isTerminalVisible.toggle()
        if isTerminalVisible && terminals.isEmpty { newTerminal() }
    }

    func newTerminal() {
        terminalCounter += 1
        let session = TerminalSession(directory: rootURL, number: terminalCounter)
        session.onExit = { [weak self] session in self?.removeTerminal(session.id) }
        terminals.append(session)
        activeTerminalID = session.id
        isTerminalVisible = true
    }

    func closeTerminal(_ id: UUID) {
        terminals.first { $0.id == id }?.terminate()
        removeTerminal(id)
    }

    private func removeTerminal(_ id: UUID) {
        guard let index = terminals.firstIndex(where: { $0.id == id }) else { return }
        terminals.remove(at: index)
        if activeTerminalID == id {
            activeTerminalID = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)].id
        }
        if terminals.isEmpty { isTerminalVisible = false }
    }
}

enum UnsavedChanges {
    /// Asks whether to save `documents`; `save` writes one and reports success. Returns false
    /// when the user cancels or a save fails.
    @MainActor
    static func confirm(_ documents: [EditorDocument], save: (EditorDocument) -> Bool) -> Bool {
        guard !documents.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = documents.count == 1
            ? "Save changes to \(documents[0].name)?"
            : "Save changes to \(documents.count) files?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return documents.allSatisfy(save)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
}
