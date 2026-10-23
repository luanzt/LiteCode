import AppKit
import SwiftUI

struct TerminalPanel: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Text("TERMINAL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.UI.inactiveForeground)
                    .padding(.trailing, 8)
                ForEach(workspace.terminals) { session in
                    TerminalTab(session: session, isActive: session.id == workspace.activeTerminalID)
                }
                Spacer()
                Button { workspace.newTerminal() } label: { LucideImage(.plus, size: 14) }
                    .help("New Terminal (⌃⇧`)")
                Button { workspace.isTerminalVisible = false } label: { LucideImage(.chevronDown, size: 14) }
                    .help("Hide Panel (⌘B)")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 28)
            ThemeDivider()
            if let session = workspace.terminals.first(where: { $0.id == workspace.activeTerminalID }) {
                TerminalContainer(session: session)
                    .padding(.leading, 6)
            }
        }
        .background(Theme.UI.chromeBackground)
    }
}

private struct TerminalTab: View {
    @Environment(Workspace.self) private var workspace
    let session: TerminalSession
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            LucideImage(.squareTerminal, size: 12)
            // Fixed width keeps every tab the same size (about 100 pt overall).
            Text(session.title).lineLimit(1).truncationMode(.middle).frame(width: 56)
            Button { workspace.closeTerminal(session.id) } label: {
                LucideImage(.x, size: 11)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(isActive ? Theme.UI.foreground : Theme.UI.inactiveForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(isActive ? Theme.UI.listActive : .clear))
        .contentShape(Rectangle())
        .onTapGesture { workspace.activeTerminalID = session.id }
    }
}

private struct TerminalContainer: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(in: container)
    }

    private func install(in container: NSView) {
        let view = session.view
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
    }
}
