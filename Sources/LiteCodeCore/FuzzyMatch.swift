/// VS Code-style fuzzy matching for Quick Open (⌘P): the query's characters must appear in order,
/// preferably in the file name, at word starts, and consecutively.
public enum FuzzyMatch {
    public struct Match: Equatable, Sendable {
        public var score: Int
        /// Matched UTF-16 offsets within the whole relative path, for highlighting.
        public var indices: [Int]
    }

    private static let gapPenalty = 1
    private static let matchScore = 16
    private static let consecutiveBonus = 8

    /// Scores `path` (relative, "/"-separated) against `query`. Spaces in the query are ignored,
    /// and a query containing "/" matches the whole path instead of preferring the file name.
    public static func match(_ query: String, path: String) -> Match? {
        let needle = Array(query.utf16.filter { $0 != 32 })
        guard !needle.isEmpty else { return Match(score: 0, indices: []) }
        let candidate = Array(path.utf16)
        let nameStart = (candidate.lastIndex(of: 47) ?? -1) + 1
        let length = candidate.count
        // Shorter paths win otherwise-equal matches.
        let lengthPenalty = length / 8

        if !needle.contains(47), let name = best(needle, in: candidate, from: nameStart) {
            let nameLength = length - nameStart
            var score = name.score + 1000
            if name.indices.first == nameStart { score += 200 }
            // "common" for common.ts: the whole stem typed.
            let stemLength = (candidate[nameStart...].firstIndex(of: 46) ?? length) - nameStart
            if needle.count == stemLength || needle.count == nameLength { score += 300 }
            return Match(score: score - lengthPenalty, indices: name.indices)
        }
        guard let whole = best(needle, in: candidate, from: 0) else { return nil }
        return Match(score: whole.score - lengthPenalty, indices: whole.indices)
    }

    /// Best alignment of `needle` within `candidate[start...]`, by dynamic programming over
    /// (query character, candidate position) like fzy: rewards word starts and runs, penalizes gaps.
    private static func best(_ needle: [UInt16], in candidate: [UInt16], from start: Int) -> Match? {
        let n = candidate.count - start
        let m = needle.count
        guard m <= n else { return nil }
        let lowered = candidate[start...].map(lower)
        let query = needle.map(lower)
        // Cheap rejection: is the query a subsequence at all?
        var cursor = 0
        for character in lowered where cursor < m && character == query[cursor] { cursor += 1 }
        guard cursor == m else { return nil }

        var bonus = [Int](repeating: 0, count: n)
        for j in 0..<n {
            let index = start + j
            let current = candidate[index]
            if index == 0 { bonus[j] = 10; continue }
            let previous = candidate[index - 1]
            switch previous {
            case 47: bonus[j] = 9                       // after "/"
            case 95, 45, 46, 32: bonus[j] = 7           // after "_", "-", ".", " "
            default: if isLower(previous) && isUpper(current) { bonus[j] = 7 }  // camelCase hump
            }
            if j == 0 { bonus[j] = max(bonus[j], 8) }
        }

        let none = Int.min / 2
        // Flattened m×n tables, row i = query character i:
        // ends[i,j]   best score with query[i] matched exactly at j;
        // upTo[i,j]   best score with query[0...i] matched within 0...j (later gaps penalized);
        // from[i,j]   where query[i-1] sits in the alignment behind ends[i,j];
        // bestAt[i,j] where query[i] sits in the alignment behind upTo[i,j].
        var ends = [Int](repeating: none, count: m * n)
        var upTo = ends
        var from = [Int](repeating: -1, count: m * n)
        var bestAt = from
        for i in 0..<m {
            let row = i * n, above = (i - 1) * n
            for j in i..<n {
                if lowered[j] == query[i] {
                    let gain = matchScore + bonus[j] + (candidate[start + j] == needle[i] ? 1 : 0)
                    if i == 0 {
                        ends[row + j] = gain - min(j, 12)
                    } else if j > 0 {
                        if ends[above + j - 1] > none {
                            ends[row + j] = ends[above + j - 1] + gain + consecutiveBonus
                            from[row + j] = j - 1
                        }
                        if upTo[above + j - 1] > none, upTo[above + j - 1] + gain > ends[row + j] {
                            ends[row + j] = upTo[above + j - 1] + gain
                            from[row + j] = bestAt[above + j - 1]
                        }
                    }
                }
                let carried = j > i && upTo[row + j - 1] > none ? upTo[row + j - 1] - gapPenalty : none
                if ends[row + j] > none && ends[row + j] >= carried {
                    upTo[row + j] = ends[row + j]
                    bestAt[row + j] = j
                } else {
                    upTo[row + j] = carried
                    bestAt[row + j] = j > i ? bestAt[row + j - 1] : -1
                }
            }
        }
        let last = (m - 1) * n + n - 1
        guard upTo[last] > none else { return nil }

        var indices = [Int](repeating: 0, count: m)
        var position = bestAt[last]
        for i in stride(from: m - 1, through: 0, by: -1) {
            guard position >= 0 else { return nil }
            indices[i] = start + position
            position = from[i * n + position]
        }
        return Match(score: upTo[last], indices: indices)
    }

    private static func lower(_ unit: UInt16) -> UInt16 { isUpper(unit) ? unit + 32 : unit }
    private static func isUpper(_ unit: UInt16) -> Bool { unit >= 65 && unit <= 90 }
    private static func isLower(_ unit: UInt16) -> Bool { unit >= 97 && unit <= 122 }
}
