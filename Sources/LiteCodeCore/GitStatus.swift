import Foundation

/// One row of the Source Control view: a file's staged (index vs HEAD) or unstaged
/// (working tree vs index) change. A partly staged file yields one of each.
public struct GitChange: Hashable, Sendable, Identifiable {
    public enum Status: String, Sendable {
        case modified = "M"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case untracked = "U"
        case conflicted = "!"
    }

    public enum Stage: String, Sendable {
        /// "Staged Changes": the index differs from HEAD.
        case staged
        /// The working tree differs from the index: "Changes", or "Merge Changes" for conflicted files.
        case unstaged
    }

    /// Path relative to the repository root.
    public var path: String
    /// Pre-rename path relative to the repository root, for `.renamed`.
    public var originalPath: String?
    public var status: Status
    public var stage: Stage

    public var id: String { stage.rawValue + ":" + path }

    public init(path: String, originalPath: String? = nil, status: Status, stage: Stage = .unstaged) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.stage = stage
    }
}

public enum GitStatusParser {
    private static let conflictCodes: Set<String> = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"]

    /// Parses `git status --porcelain=v1 -z` output. The first status column describes the
    /// index (staged), the second the working tree (unstaged). Renames and copies carry their
    /// source path as the following NUL-separated field.
    public static func parse(_ output: String) -> [GitChange] {
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        var changes: [GitChange] = []
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            if code == "!!" { continue }
            if code == "??" {
                changes.append(GitChange(path: path, status: .untracked))
                continue
            }
            if conflictCodes.contains(code) {
                changes.append(GitChange(path: path, status: .conflicted))
                continue
            }
            let index = code.first!, workTree = code.last!
            let originalPath = "RC".contains(index) || "RC".contains(workTree) ? fields.next().map(String.init) : nil
            if index != " " {
                let status = status(for: index)
                changes.append(GitChange(path: path, originalPath: status == .renamed ? originalPath : nil,
                                         status: status, stage: .staged))
            }
            if workTree != " " {
                changes.append(GitChange(path: path, status: status(for: workTree)))
            }
        }
        return changes.sorted {
            let order = $0.path.localizedStandardCompare($1.path)
            return order == .orderedSame ? $0.stage == .staged && $1.stage == .unstaged : order == .orderedAscending
        }
    }

    private static func status(for code: Character) -> GitChange.Status {
        switch code {
        case "A", "C": .added
        case "D": .deleted
        case "R": .renamed
        default: .modified
        }
    }
}
