/// Structure the regex highlighter can't express: JSX elements and bracket nesting. Both scan
/// UTF-16 code units and ignore the units a caller marks as strings or comments.

/// Parts of a JSX element, as VS Code's JSX/TSX grammars scope them.
public enum JSXPart: Equatable, Sendable {
    /// `<`, `</`, `>`, `/>`, and the `<>` / `</>` of fragments.
    case punctuation
    /// Lowercase intrinsic element name (`div`).
    case tag
    /// Capitalized or dotted component name (`View`, `Tab.Item`).
    case component
    case attribute
    /// Text between tags.
    case text
}

public enum JSXScanner {
    private enum Context {
        /// Inside `<Name …`, reading attributes.
        case tag
        /// Between an opening and a closing tag.
        case children
        /// Inside `{…}` within a tag or children; `depth` counts open braces.
        case expression(depth: Int)
    }

    /// Reports each element part in source order. `isLiteral(i)` is true for units inside strings
    /// and comments, which can't start elements or braces outside element children.
    public static func scan(_ chars: [UInt16], isLiteral: (Int) -> Bool, mark: (Range<Int>, JSXPart) -> Void) {
        var stack: [Context] = []
        var i = 0
        while i < chars.count {
            let char = chars[i]
            switch stack.last {
            case .tag?:
                if isLiteral(i) || isSpace(char) || char == equals {
                    i += 1
                } else if char == slash, i + 1 < chars.count, chars[i + 1] == greater {
                    mark(i..<i + 2, .punctuation)
                    stack.removeLast()
                    i += 2
                } else if char == greater {
                    mark(i..<i + 1, .punctuation)
                    stack[stack.count - 1] = .children
                    i += 1
                } else if char == openBrace {
                    stack.append(.expression(depth: 1))
                    i += 1
                } else if isIdentifierStart(char) {
                    let end = nameEnd(chars, from: i)
                    mark(i..<end, .attribute)
                    i = end
                } else {
                    // Not an element after all (`a <b && c`): resume in the enclosing context.
                    stack.removeLast()
                }
            case .children?:
                if char == openBrace {
                    stack.append(.expression(depth: 1))
                    i += 1
                } else if char == less, let next = element(chars, at: i, stack: &stack, mark: mark) {
                    i = next
                } else {
                    var end = i + 1
                    while end < chars.count, chars[end] != openBrace, chars[end] != less { end += 1 }
                    mark(i..<end, .text)
                    i = end
                }
            case .expression(let depth)?:
                if isLiteral(i) {
                    i += 1
                } else if char == openBrace {
                    stack[stack.count - 1] = .expression(depth: depth + 1)
                    i += 1
                } else if char == closeBrace {
                    if depth == 1 { stack.removeLast() } else { stack[stack.count - 1] = .expression(depth: depth - 1) }
                    i += 1
                } else {
                    i = code(chars, at: i, isLiteral: isLiteral, stack: &stack, mark: mark)
                }
            case nil:
                i = isLiteral(i) ? i + 1 : code(chars, at: i, isLiteral: isLiteral, stack: &stack, mark: mark)
            }
        }
    }

    /// One unit of plain code: an element when a `<` can start one there.
    private static func code(_ chars: [UInt16], at i: Int, isLiteral: (Int) -> Bool,
                             stack: inout [Context], mark: (Range<Int>, JSXPart) -> Void) -> Int {
        guard chars[i] == less, opensElement(chars, at: i, isLiteral: isLiteral),
              let next = element(chars, at: i, stack: &stack, mark: mark) else { return i + 1 }
        return next
    }

    /// Reads a tag at `<`: a closing tag (only in children), a fragment, or an opening tag name.
    private static func element(_ chars: [UInt16], at i: Int, stack: inout [Context],
                                mark: (Range<Int>, JSXPart) -> Void) -> Int? {
        guard i + 1 < chars.count else { return nil }
        let next = chars[i + 1]
        if next == slash {
            guard case .children? = stack.last else { return nil }
            var j = i + 2
            while j < chars.count, isSpace(chars[j]) { j += 1 }
            let nameStart = j
            if j < chars.count, isIdentifierStart(chars[j]) { j = nameEnd(chars, from: j) }
            let name = nameStart..<j
            while j < chars.count, isSpace(chars[j]) { j += 1 }
            guard j < chars.count, chars[j] == greater else { return nil }
            mark(i..<i + 2, .punctuation)
            if !name.isEmpty { mark(name, part(ofName: name, in: chars)) }
            mark(j..<j + 1, .punctuation)
            stack.removeLast()
            return j + 1
        }
        if next == greater {
            mark(i..<i + 2, .punctuation)
            stack.append(.children)
            return i + 2
        }
        guard isIdentifierStart(next) else { return nil }
        let name = (i + 1)..<nameEnd(chars, from: i + 1)
        mark(i..<i + 1, .punctuation)
        mark(name, part(ofName: name, in: chars))
        stack.append(.tag)
        return name.upperBound
    }

    /// In code, `<` starts an element only where an expression can begin: not after an operand
    /// (`a<b`, `useState<T>`, `f() < 1`), except after keywords like `return`.
    private static func opensElement(_ chars: [UInt16], at i: Int, isLiteral: (Int) -> Bool) -> Bool {
        guard i + 1 < chars.count, isIdentifierStart(chars[i + 1]) || chars[i + 1] == greater else { return false }
        var k = i - 1
        while k >= 0, isSpace(chars[k]) { k -= 1 }
        guard k >= 0 else { return true }
        let previous = chars[k]
        if isIdentifierPart(previous) {
            var start = k
            while start > 0, isIdentifierPart(chars[start - 1]) { start -= 1 }
            let word = String(decoding: chars[start...k], as: UTF16.self)
            return expressionKeywords.contains(word)
        }
        return !isLiteral(k) && ![closeParen, closeBracket, closeBrace, dot].contains(previous)
    }

    private static func part(ofName name: Range<Int>, in chars: [UInt16]) -> JSXPart {
        let first = chars[name.lowerBound]
        let isUpper = first >= 65 && first <= 90
        return isUpper || chars[name].contains(dot) ? .component : .tag
    }

    /// End of a tag or attribute name: identifier characters plus `.` (`Tab.Item`), `-`, `:`.
    private static func nameEnd(_ chars: [UInt16], from start: Int) -> Int {
        var end = start + 1
        while end < chars.count, isIdentifierPart(chars[end]) || chars[end] == dot || chars[end] == 45 || chars[end] == 58 {
            end += 1
        }
        return end
    }

    private static let expressionKeywords: Set<String> = ["return", "yield", "await", "default", "case", "else", "do"]

    private static let less: UInt16 = 60, greater: UInt16 = 62, slash: UInt16 = 47, equals: UInt16 = 61
    private static let openBrace: UInt16 = 123, closeBrace: UInt16 = 125
    private static let closeParen: UInt16 = 41, closeBracket: UInt16 = 93, dot: UInt16 = 46
}

/// VS Code's bracket pair colorization: `()`, `[]` and `{}` by nesting depth.
public enum BracketPairs {
    /// Reports `(index, depth)` for every opening bracket and every closing bracket that matches
    /// the innermost open one; depth 0 is outermost. Mismatched closers are not reported.
    public static func scan(_ chars: [UInt16], skip: (Int) -> Bool, mark: (Int, Int) -> Void) {
        var open: [UInt16] = []
        for i in chars.indices where !skip(i) {
            switch chars[i] {
            case 40, 91, 123:
                mark(i, open.count)
                open.append(chars[i])
            case 41, 93, 125:
                // `)` is `(` + 1; `]` and `}` are their openers + 2.
                let opener = chars[i] == 41 ? 40 : chars[i] - 2
                if open.last == opener {
                    open.removeLast()
                    mark(i, open.count)
                }
            default:
                break
            }
        }
    }
}

private func isSpace(_ char: UInt16) -> Bool { char == 32 || char == 9 || char == 10 || char == 13 }

private func isIdentifierStart(_ char: UInt16) -> Bool {
    (char >= 65 && char <= 90) || (char >= 97 && char <= 122) || char == 95 || char == 36 || char >= 0x80
}

private func isIdentifierPart(_ char: UInt16) -> Bool { isIdentifierStart(char) || (char >= 48 && char <= 57) }
