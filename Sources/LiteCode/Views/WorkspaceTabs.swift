import SwiftUI

/// Workspace switcher in the title bar: one tab per open folder, plus a button to add one.
struct WorkspaceTabStrip: View {
    @Environment(Workspaces.self) private var workspaces
    /// Workspace being dragged; tabs reorder live as it passes over them.
    @State private var draggingID: Workspace.ID?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(workspaces.all) { workspace in
                WorkspaceTab(workspace: workspace, isActive: workspace.id == workspaces.activeID)
                    .onDrag {
                        draggingID = workspace.id
                        return NSItemProvider(object: workspace.rootURL.path as NSString)
                    }
                    .onDrop(of: [.text], delegate: ReorderDropDelegate(
                        target: workspace.id, workspaces: workspaces, draggingID: $draggingID))
            }
            Button { workspaces.promptAdd() } label: {
                LucideImage(.plus, size: 14)
                    .foregroundStyle(Theme.UI.inactiveForeground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add Workspace (⌘O)")
        }
    }
}

/// Reorders while hovering, so the dragged tab slides into place before the drop.
private struct ReorderDropDelegate: DropDelegate {
    let target: Workspace.ID
    let workspaces: Workspaces
    @Binding var draggingID: Workspace.ID?

    func dropEntered(info: DropInfo) {
        guard let draggingID, draggingID != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { workspaces.move(draggingID, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

private struct WorkspaceTab: View {
    @Environment(Workspaces.self) private var workspaces
    let workspace: Workspace
    let isActive: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            FileIcon(name: workspace.name, isDirectory: true)
            Text(workspace.name)
                .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
            Button { workspaces.close(workspace) } label: {
                Group {
                    if !workspace.dirtyDocuments.isEmpty && !isHovered {
                        Circle().frame(width: 7, height: 7)
                    } else {
                        LucideImage(.x, size: 12)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || !workspace.dirtyDocuments.isEmpty ? 1 : 0)
            .help("Close Workspace")
        }
        .foregroundStyle(isActive ? Theme.UI.foreground : Theme.UI.inactiveForeground)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Theme.UI.listActive : (isHovered ? Theme.UI.listHover : .clear)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { workspaces.activate(workspace) }
        .help(workspace.rootURL.path)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.rootURL]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspace.rootURL.path, forType: .string)
            }
            Divider()
            Button("Close Workspace") { workspaces.close(workspace) }
        }
    }
}
