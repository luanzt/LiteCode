import AppKit
import SwiftTerm

/// One shell running in a pseudo-terminal. The view outlives panel toggles so scrollback stays.
@MainActor
final class TerminalSession: Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    /// "zsh 1", "zsh 2", …; the shell's own title escapes (user@host:path) are ignored.
    let title: String
    let view: LocalProcessTerminalView
    var onExit: ((TerminalSession) -> Void)?

    init(directory: URL, number: Int) {
        let environment = ProcessInfo.processInfo.environment
        let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        title = "\((shell as NSString).lastPathComponent) \(number)"
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // Oh My Dark terminal.* colors.
        view.installColors(Theme.terminalANSI.map { SwiftTerm.Color(rgb: $0) })
        view.nativeBackgroundColor = Theme.terminalBackground
        view.nativeForegroundColor = Theme.terminalForeground
        view.layer?.backgroundColor = Theme.terminalBackground.cgColor
        view.caretColor = Theme.cursor
        view.selectedTextBackgroundColor = Theme.terminalSelection
        view.processDelegate = self

        var variables = environment
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["TERM_PROGRAM"] = "LiteCode"
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }
        // A leading "-" in argv[0] makes the shell a login shell, so Finder launches still get
        // the user's profile PATH.
        view.startProcess(
            executable: shell,
            args: [],
            environment: variables.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: directory.path)
    }

    func terminate() {
        view.terminate()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(self)
    }
}
