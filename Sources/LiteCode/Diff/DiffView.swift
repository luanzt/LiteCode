import AppKit
import LiteCodeCore
import SwiftUI

struct DiffView: View {
    @Environment(Workspace.self) private var workspace
    let document: DiffDocument

    var body: some View {
        VStack(spacing: 0) {
            header
            ThemeDivider()
            content
        }
        .background(Theme.UI.editorBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusBadge(status: document.change.status)
            Text(document.change.path)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
            if let original = document.change.originalPath {
                Text("← \(original)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if document.isLoaded && !document.isBinary {
                Text("+\(document.addedCount)").foregroundStyle(Theme.UI.gitAdded)
                Text("−\(document.removedCount)").foregroundStyle(Theme.UI.gitDeleted)
                HStack(spacing: 0) {
                    HeaderIconButton(icon: .arrowUp, help: "Previous Change") { document.revealChange(-1) }
                    HeaderIconButton(icon: .arrowDown, help: "Next Change") { document.revealChange(1) }
                }
                .disabled(document.hunkCount == 0)
            }
            Button("Open File") { workspace.openFile(document.fileURL) }
                .buttonStyle(ThemeButtonStyle())
                .disabled(document.change.status == .deleted)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if document.isBinary {
            placeholder("Binary file — no text diff")
        } else {
            // Mounted while loading too, so the panes are on screen when the first load lands;
            // kept when no changes remain, so the editable side stays usable.
            DiffPanes(document: document)
                .overlay { if !document.isLoaded { ProgressView() } }
                .overlay(alignment: .topTrailing) {
                    if document.find.isVisible {
                        FindWidget(find: document.find).padding(.trailing, 16)
                    }
                }
                .onChange(of: document.isLoaded, initial: true) {
                    DispatchQueue.main.async { document.revealFirstChangeIfNeeded() }
                }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HeaderIconButton: View {
    let icon: LucideIcon
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            LucideImage(icon, size: 15)
                .foregroundStyle(isEnabled ? Theme.UI.foreground : Theme.UI.inactiveForeground)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(isHovered && isEnabled ? Theme.UI.listHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Hosts the document's views: left pane, action gutter, right pane.
private struct DiffPanes: NSViewRepresentable {
    let document: DiffDocument

    func makeNSView(context: Context) -> SplitContainer {
        let container = SplitContainer()
        container.install(document.views)
        return container
    }

    func updateNSView(_ container: SplitContainer, context: Context) {
        container.install(document.views)
    }

    final class SplitContainer: NSView {
        override var isFlipped: Bool { true }

        func install(_ views: DiffViews) {
            // The overview ruler goes last, over the right pane's scroller track.
            let wanted = [views.left.scrollView, views.gutter, views.right.scrollView, views.overview]
            guard subviews != wanted else { return }
            subviews.forEach { $0.removeFromSuperview() }
            wanted.forEach(addSubview)
            needsLayout = true
        }

        override func layout() {
            super.layout()
            guard subviews.count == 4 else { return }
            let gutter = DiffActionGutter.width
            let half = ((bounds.width - gutter) / 2).rounded(.down)
            subviews[0].frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
            subviews[1].frame = NSRect(x: half, y: 0, width: gutter, height: bounds.height)
            subviews[2].frame = NSRect(x: half + gutter, y: 0, width: bounds.width - half - gutter, height: bounds.height)
            subviews[3].frame = NSRect(x: bounds.width - 10, y: 0, width: 10, height: bounds.height)
        }
    }
}

struct StatusBadge: View {
    let status: GitChange.Status

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(status.color)
    }
}

extension GitChange.Status {
    /// gitDecoration.*ResourceForeground; renames share the added color (the theme has no
    /// renamed key), conflicts use the terminal magenta.
    var color: Color {
        switch self {
        case .modified: Color(nsColor: Theme.gitModified)
        case .added, .renamed: Color(nsColor: Theme.gitAdded)
        case .untracked: Color(nsColor: Theme.gitUntracked)
        case .deleted: Color(nsColor: Theme.gitDeleted)
        case .conflicted: Color(nsColor: Theme.gitConflict)
        }
    }
}
