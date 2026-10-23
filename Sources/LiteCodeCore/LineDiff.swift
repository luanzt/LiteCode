/// One row of a side-by-side diff. `left`/`right` are 0-based line indices into the
/// original and modified files; a nil side renders as an empty filler cell.
public struct DiffRow: Equatable, Sendable {
    public enum Kind: Sendable { case same, removed, added, changed }

    public var kind: Kind
    public var left: Int?
    public var right: Int?

    public init(kind: Kind, left: Int?, right: Int?) {
        self.kind = kind
        self.left = left
        self.right = right
    }
}

public enum LineDiff {
    /// Lines of a file for diffing: a trailing newline doesn't add an empty last line, and
    /// CRLF endings are normalized.
    public static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var text = text
        // removeLast drops a whole Character, so a trailing "\r\n" goes in one step.
        if text.utf8.last == UInt8(ascii: "\n") { text.removeLast() }
        return text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Aligns two files line by line. Adjacent removals and insertions are paired into
    /// `.changed` rows so an edited line sits next to its replacement.
    public static func rows(original: [String], modified: [String]) -> [DiffRow] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in modified.difference(from: original) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [DiffRow] = []
        rows.reserveCapacity(max(original.count, modified.count))
        var i = 0, j = 0
        while i < original.count || j < modified.count {
            let leftChanged = i < original.count && removed.contains(i)
            let rightChanged = j < modified.count && inserted.contains(j)
            if leftChanged || rightChanged {
                var lefts: [Int] = []
                var rights: [Int] = []
                while i < original.count && removed.contains(i) { lefts.append(i); i += 1 }
                while j < modified.count && inserted.contains(j) { rights.append(j); j += 1 }
                for k in 0..<max(lefts.count, rights.count) {
                    let l = k < lefts.count ? lefts[k] : nil
                    let r = k < rights.count ? rights[k] : nil
                    let kind: DiffRow.Kind = l != nil && r != nil ? .changed : (l != nil ? .removed : .added)
                    rows.append(DiffRow(kind: kind, left: l, right: r))
                }
            } else {
                // Unchanged lines map in order, so both sides run out together.
                guard i < original.count, j < modified.count else { break }
                rows.append(DiffRow(kind: .same, left: i, right: j))
                i += 1
                j += 1
            }
        }
        return rows
    }

    /// One run of changed rows, with the line ranges it covers on each side. A side without
    /// lines in the hunk gets an empty range at the insertion point.
    public struct Hunk: Equatable, Sendable {
        public var rows: Range<Int>
        public var original: Range<Int>
        public var modified: Range<Int>

        public init(rows: Range<Int>, original: Range<Int>, modified: Range<Int>) {
            self.rows = rows
            self.original = original
            self.modified = modified
        }
    }

    public static func hunks(_ rows: [DiffRow]) -> [Hunk] {
        var hunks: [Hunk] = []
        var left = 0, right = 0
        var start: (row: Int, left: Int, right: Int)?
        for (index, row) in rows.enumerated() {
            if row.kind == .same {
                if let open = start {
                    hunks.append(Hunk(rows: open.row..<index, original: open.left..<left, modified: open.right..<right))
                    start = nil
                }
            } else if start == nil {
                start = (index, left, right)
            }
            if row.left != nil { left += 1 }
            if row.right != nil { right += 1 }
        }
        if let open = start {
            hunks.append(Hunk(rows: open.row..<rows.count, original: open.left..<left, modified: open.right..<right))
        }
        return hunks
    }

    /// `lines` with `range` replaced, for applying one hunk's other side.
    public static func replacing(_ range: Range<Int>, in lines: [String], with replacement: some Collection<String>) -> [String] {
        var result = lines
        result.replaceSubrange(range, with: replacement)
        return result
    }

    /// The differing middle of an edited line pair, as UTF-16 offsets into each line: what is
    /// left after removing the common prefix and suffix. Nil when nothing is shared, since
    /// emphasizing the whole line would add nothing to the line's own tint.
    public static func changedSpan(_ old: String, _ new: String) -> (old: Range<Int>, new: Range<Int>)? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        guard prefix + suffix > 0, a != b else { return nil }
        return (prefix..<(a.count - suffix), prefix..<(b.count - suffix))
    }
}
