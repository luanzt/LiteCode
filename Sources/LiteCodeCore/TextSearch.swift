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

/// One search result row's text: a line shortened around one match, as VS Code shows it.
public struct SearchPreview: Equatable, Sendable {
    public var text: String
    /// The match within `text` (UTF-16).
    public var match: NSRange

    public init(text: String, match: NSRange) {
        self.text = text
        self.match = match
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

    /// VS Code's preview (`Match.preview` + `lcut`): leading whitespace trimmed, the text before
    /// the match cut at a word boundary to about 26 characters behind a "…", and the whole row
    /// capped at 250 characters.
    public static func preview(of line: String, match: NSRange) -> SearchPreview {
        let ns = line as NSString
        let start = min(match.location, ns.length)
        let end = min(NSMaxRange(match), ns.length)
        let before = leadingCut(ns.substring(to: start), keeping: 26)
        var remaining = maxPreviewLength - (before as NSString).length
        let inside = prefix(ns.substring(with: NSRange(location: start, length: end - start)), remaining)
        remaining -= (inside as NSString).length
        let after = prefix(ns.substring(from: end), remaining)
        return SearchPreview(text: before + inside + after,
                             match: NSRange(location: (before as NSString).length, length: (inside as NSString).length))
    }

    private static let maxPreviewLength = 250

    /// VS Code's `lcut`: drops leading whitespace, then whole words from the front while at least
    /// `count` characters would remain, prefixing "…" when anything was dropped.
    private static func leadingCut(_ text: String, keeping count: Int) -> String {
        let trimmed = trimmingLeadingWhitespace(text)
        let units = Array(trimmed.utf16)
        guard units.count >= count else { return trimmed }
        var cut = 0
        for position in 1..<units.count where isWordUnit(units[position - 1]) != isWordUnit(units[position]) {
            if units.count - position < count { break }
            cut = position
        }
        guard cut > 0 else { return trimmed }
        return "…" + trimmingLeadingWhitespace((trimmed as NSString).substring(from: cut))
    }

    /// JavaScript's `\w`, which decides `\b` word boundaries.
    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
    }

    private static func trimmingLeadingWhitespace(_ text: String) -> String {
        String(text.drop { $0.isWhitespace })
    }

    /// At most `length` UTF-16 units, without splitting a character.
    private static func prefix(_ text: String, _ length: Int) -> String {
        let ns = text as NSString
        guard length > 0 else { return "" }
        guard ns.length > length else { return text }
        return ns.substring(with: ns.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: length)))
    }
}
