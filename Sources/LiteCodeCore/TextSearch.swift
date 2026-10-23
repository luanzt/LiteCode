import Foundation

public struct SearchOptions: Equatable, Sendable {
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(query: String, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }

    /// The compiled pattern; throws for an invalid regular expression.
    public func expression() throws -> NSRegularExpression {
        var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

/// All matches on one line of a file.
public struct LineMatch: Equatable, Sendable {
    /// 0-based line number.
    public var line: Int
    /// The line's text, without its newline.
    public var text: String
    /// UTF-16 ranges within `text`.
    public var ranges: [NSRange]

    public init(line: Int, text: String, ranges: [NSRange]) {
        self.line = line
        self.text = text
        self.ranges = ranges
    }
}

public enum TextSearch {
    /// Matches of `expression` in `text`, grouped by line. Matches spanning lines are attributed
    /// to the line where they start and clipped to it. Stops after `limit` matches.
    public static func matches(of expression: NSRegularExpression, in text: String, limit: Int = .max) -> [LineMatch] {
        let ns = text as NSString
        var results: [LineMatch] = []
        var count = 0
        var lineNumber = 0
        var lineStart = 0
        expression.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            // Advance the line counter to the line containing this match.
            while true {
                let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
                if match.range.location < NSMaxRange(lineRange) || NSMaxRange(lineRange) >= ns.length { break }
                lineStart = NSMaxRange(lineRange)
                lineNumber += 1
            }
            var contentsEnd = 0
            ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let lineText = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
            let start = match.range.location - lineStart
            let range = NSRange(location: start, length: min(match.range.length, contentsEnd - match.range.location))
            if let last = results.last, last.line == lineNumber {
                results[results.count - 1].ranges.append(range)
            } else {
                results.append(LineMatch(line: lineNumber, text: lineText, ranges: [range]))
            }
            count += 1
            if count >= limit { stop.pointee = true }
        }
        return results
    }
}
