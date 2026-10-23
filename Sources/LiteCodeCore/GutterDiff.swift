import Foundation

/// Change markers for an editor gutter, relative to a base version of the file — what VS Code
/// draws next to line numbers (added, modified, deleted).
public struct GutterMarks: Equatable, Sendable {
    /// 0-based lines that are new.
    public var added = IndexSet()
    /// 0-based lines that replace base lines.
    public var modified = IndexSet()
    /// Positions where base lines were removed: `n` means "just before line n" (`n` may equal
    /// the line count, meaning after the last line).
    public var deletedBefore = IndexSet()

    public init(added: IndexSet = [], modified: IndexSet = [], deletedBefore: IndexSet = []) {
        self.added = added
        self.modified = modified
        self.deletedBefore = deletedBefore
    }

    public var isEmpty: Bool { added.isEmpty && modified.isEmpty && deletedBefore.isEmpty }

    public static func compute(base: [String], current: [String]) -> GutterMarks {
        var marks = GutterMarks()
        let rows = LineDiff.rows(original: base, modified: current)
        var nextRight = 0
        var pendingDeletion = false
        for row in rows {
            if let right = row.right {
                if pendingDeletion {
                    marks.deletedBefore.insert(right)
                    pendingDeletion = false
                }
                switch row.kind {
                case .added: marks.added.insert(right)
                case .changed: marks.modified.insert(right)
                case .same, .removed: break
                }
                nextRight = right + 1
            } else {
                pendingDeletion = true
            }
        }
        if pendingDeletion { marks.deletedBefore.insert(nextRight) }
        return marks
    }
}
