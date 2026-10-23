import AppKit

/// Regex-based highlighting: cheap, language-agnostic enough for a light editor.
struct Language {
    var name: String
    var lineComment: String?
    /// Token rules applied in order; later rules win where they overlap.
    var rules: [(NSRegularExpression, SyntaxToken)]

    static func detect(_ url: URL) -> Language {
        let ext = url.pathExtension.lowercased()
        let file = url.lastPathComponent.lowercased()
        switch ext {
        case "swift": return .cLike("Swift", swiftKeywords)
        case "js", "jsx", "mjs", "cjs": return .cLike("JavaScript", jsKeywords, backticks: true)
        case "ts", "tsx", "mts", "cts": return .cLike("TypeScript", jsKeywords + tsKeywords, backticks: true)
        case "go": return .cLike("Go", goKeywords, backticks: true)
        case "rs": return .cLike("Rust", rustKeywords)
        case "java": return .cLike("Java", javaKeywords)
        case "kt", "kts": return .cLike("Kotlin", kotlinKeywords)
        case "c", "h": return .cLike("C", cKeywords)
        case "cpp", "cc", "cxx", "hpp", "hh", "m", "mm": return .cLike("C++", cKeywords + cppKeywords)
        case "cs": return .cLike("C#", javaKeywords + ["namespace", "using", "var", "async", "await", "readonly", "override", "virtual", "get", "set"])
        case "dart": return .cLike("Dart", javaKeywords + ["var", "final", "async", "await", "late", "required", "dynamic", "Future"])
        case "php": return .cLike("PHP", jsKeywords + ["echo", "function", "namespace", "use", "public", "private", "protected"])
        case "css", "scss", "less": return .css
        case "py", "pyi": return .hashComment("Python", pythonKeywords, tripleQuotes: true)
        case "rb": return .hashComment("Ruby", rubyKeywords)
        case "sh", "bash", "zsh", "fish": return .hashComment("Shell", shellKeywords)
        case "yml", "yaml": return .yaml
        case "toml", "ini", "cfg", "conf", "env": return .hashComment("Config", ["true", "false"])
        case "json", "jsonc": return .json
        case "md", "markdown": return .markdown
        case "html", "htm", "xml", "svg", "plist", "vue": return .markup
        case "sql": return .sql
        default: break
        }
        switch file {
        case "makefile", "dockerfile", "gemfile", "podfile", "rakefile", ".gitignore", ".env", ".zshrc", ".bashrc":
            return .hashComment(file.capitalized, shellKeywords)
        default:
            return Language(name: "Plain Text", lineComment: nil, rules: [])
        }
    }

    // MARK: Builders

    private static func rx(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func keywords(_ words: [String]) -> NSRegularExpression {
        rx("\\b(?:" + words.joined(separator: "|") + ")\\b")
    }

    private static let number = rx("\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b")
    private static let typeName = rx("\\b[A-Z][A-Za-z0-9_]*\\b")
    private static let call = rx("\\b[a-z_][A-Za-z0-9_]*(?=\\()")
    /// Language constants (Dracula "Constants") and receiver keywords (Dracula "this, self"),
    /// applied after keyword lists so they override them.
    private static let languageConstant = rx("\\b(?:true|false|nil|null|undefined|None|True|False|NULL|nullptr|YES|NO|iota)\\b")
    private static let languageVariable = rx("\\b(?:self|Self|this|super)\\b")
    private static let doubleQuoted = "\"(?:[^\"\\\\\\n]|\\\\.)*\""
    private static let singleQuoted = "'(?:[^'\\\\\\n]|\\\\.)*'"
    private static let backtick = "`(?:[^`\\\\]|\\\\.)*`"

    /// Strings and comments as one alternation, so whichever starts first wins
    /// (`"//"` stays a string, `// "x"` stays a comment).
    private static func stringsAndComments(_ alternatives: [String]) -> NSRegularExpression {
        rx(alternatives.map { "(\($0))" }.joined(separator: "|"), [.dotMatchesLineSeparators])
    }

    private static func cLike(_ name: String, _ words: [String], backticks: Bool = false) -> Language {
        var alternatives = ["//[^\\n]*", "/\\*.*?\\*/", doubleQuoted, singleQuoted]
        if backticks { alternatives.append(backtick) }
        return Language(name: name, lineComment: "//", rules: [
            (typeName, .type),
            (call, .function),
            (keywords(words), .keyword),
            (rx("^\\s*#\\s*\\w+", [.anchorsMatchLines]), .keyword),
            (rx("@\\w+"), .decorator),
            (languageConstant, .constant),
            (languageVariable, .languageVariable),
            (number, .constant),
            (stringsAndComments(alternatives), .stringOrComment),
        ])
    }

    private static func hashComment(_ name: String, _ words: [String], tripleQuotes: Bool = false) -> Language {
        var alternatives = ["#[^\\n]*", doubleQuoted, singleQuoted]
        if tripleQuotes { alternatives.insert(contentsOf: ["\"\"\".*?\"\"\"", "'''.*?'''"], at: 1) }
        var rules: [(NSRegularExpression, SyntaxToken)] = [
            (call, .function),
            (keywords(words), .keyword),
            (languageConstant, .constant),
            (languageVariable, .languageVariable),
            (number, .constant),
            (stringsAndComments(alternatives), .stringOrComment),
        ]
        if name == "Python" {
            rules.insert((typeName, .type), at: 0)
            rules.insert((rx("@\\w+"), .decorator), at: 2)
        }
        // Dracula colors "$"-prefixed shell variables as constants.
        if name == "Shell" { rules.insert((rx("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?"), .constant), at: 0) }
        return Language(name: name, lineComment: "#", rules: rules)
    }

    private static let json = Language(name: "JSON", lineComment: "//", rules: [
        (keywords(["true", "false", "null"]), .constant),
        (number, .constant),
        (stringsAndComments(["//[^\\n]*", doubleQuoted]), .stringOrComment),
        (rx("\"(?:[^\"\\\\\\n]|\\\\.)*\"(?=\\s*:)"), .property),
    ])

    private static let yaml = Language(name: "YAML", lineComment: "#", rules: [
        (rx("^\\s*-?\\s*[^\\s#:][^:\\n]*(?=:(?:\\s|$))", [.anchorsMatchLines]), .property),
        (keywords(["true", "false", "null", "yes", "no"]), .constant),
        (number, .constant),
        (stringsAndComments(["#[^\\n]*", doubleQuoted, singleQuoted]), .stringOrComment),
    ])

    private static let css = Language(name: "CSS", lineComment: nil, rules: [
        (rx("[.#&]?[A-Za-z_-][\\w-]*(?=[^{};]*\\{)"), .keyword),
        (rx("[\\w-]+(?=\\s*:[^;{]*;)"), .property),
        (rx("-?\\b\\d+(?:\\.\\d+)?(?:px|em|rem|%|vh|vw|s|ms|deg)?\\b|#[0-9a-fA-F]{3,8}\\b"), .constant),
        (stringsAndComments(["/\\*.*?\\*/", doubleQuoted, singleQuoted]), .stringOrComment),
    ])

    private static let markdown = Language(name: "Markdown", lineComment: nil, rules: [
        (rx("^#{1,6} [^\\n]*", [.anchorsMatchLines]), .heading),
        (rx("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__"), .emphasis),
        (rx("\\[[^\\]\\n]+\\]\\([^)\\n]+\\)"), .link),
        (rx("^\\s*(?:[-*+>]|\\d+\\.) ", [.anchorsMatchLines]), .link),
        (rx("```.*?```|`[^`\\n]+`", [.dotMatchesLineSeparators]), .code),
    ])

    private static let markup = Language(name: "Markup", lineComment: nil, rules: [
        (rx("</?[A-Za-z][\\w:.-]*|/?>"), .keyword),
        (rx("\\b[\\w:-]+(?==)"), .attribute),
        (stringsAndComments([doubleQuoted, singleQuoted]), .string),
        (rx("<!--.*?-->", [.dotMatchesLineSeparators]), .comment),
    ])

    private static let sql = Language(name: "SQL", lineComment: "--", rules: [
        (rx("\\b(?:select|from|where|insert|into|values|update|set|delete|create|table|alter|drop|index|join|left|right|inner|outer|on|and|or|not|null|as|order|by|group|having|limit|offset|primary|key|references|default|unique|distinct|union|case|when|then|else|end|begin|commit|exists|in|is|like)\\b", [.caseInsensitive]), .keyword),
        (number, .constant),
        (stringsAndComments(["--[^\\n]*", "/\\*.*?\\*/", singleQuoted, doubleQuoted]), .stringOrComment),
    ])

    // MARK: Keyword lists

    private static let swiftKeywords = ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "willSet"]
    private static let jsKeywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined", "var", "void", "while", "yield"]
    private static let tsKeywords = ["abstract", "as", "declare", "enum", "implements", "interface", "keyof", "namespace", "private", "protected", "public", "readonly", "satisfies", "type"]
    private static let goKeywords = ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil", "package", "range", "return", "select", "struct", "switch", "true", "type", "var"]
    private static let rustKeywords = ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
    private static let javaKeywords = ["abstract", "boolean", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null", "package", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "throws", "true", "try", "void", "while"]
    private static let kotlinKeywords = javaKeywords + ["fun", "val", "var", "when", "object", "companion", "data", "sealed", "suspend", "override", "internal", "is", "as", "in", "lateinit", "by"]
    private static let cKeywords = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "NULL"]
    private static let cppKeywords = ["class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "override", "new", "delete", "this", "true", "false", "nullptr", "using", "auto", "constexpr", "try", "catch", "throw", "self", "nil", "YES", "NO"]
    private static let pythonKeywords = ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"]
    private static let rubyKeywords = ["begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "and", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "unless", "until", "when", "while", "yield", "require", "attr_accessor"]
    private static let shellKeywords = ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "source", "echo", "exit", "set", "unset", "readonly", "shift", "true", "false", "FROM", "RUN", "CMD", "COPY", "ADD", "WORKDIR", "ENV", "EXPOSE", "ENTRYPOINT", "ARG"]
}

/// Highlight categories, styled with Oh My Dark's Dracula Soft token colors.
enum SyntaxToken: UInt8, CaseIterable {
    case keyword, string, comment, constant, languageVariable, type, function, decorator
    case property, attribute, heading, emphasis, link, code
    /// Strings-and-comments alternation; resolved per match to `.string` or `.comment`.
    case stringOrComment

    var color: NSColor {
        switch self {
        case .keyword: Palette.pink
        case .string, .stringOrComment: Palette.yellow
        case .comment: Palette.comment
        case .constant, .languageVariable, .heading: Palette.purple
        case .type, .property, .link: Palette.cyan
        case .function, .decorator, .attribute, .code: Palette.green
        case .emphasis: Palette.orange
        }
    }

    /// Dracula Soft values: Keywords/Storage, Strings, Comments, Constants and this/self,
    /// Types/Keys/Links, Functions/Decorators/attribute names, bold markup.
    private enum Palette {
        static let pink = NSColor(hex: "#f286c4")
        static let yellow = NSColor(hex: "#e7ee98")
        static let comment = NSColor(hex: "#7b7f8b")
        static let purple = NSColor(hex: "#bf9eee")
        static let cyan = NSColor(hex: "#97e1f1")
        static let green = NSColor(hex: "#62e884")
        static let orange = NSColor(hex: "#FFB86C")
    }

    var isItalic: Bool {
        switch self {
        case .languageVariable, .type, .decorator, .attribute: true
        default: false
        }
    }

    var isBold: Bool { self == .heading || self == .emphasis }
}

/// A stretch of text with one style; `token == nil` is plain text.
struct StyleRun: Equatable {
    var range: NSRange
    var token: SyntaxToken?
}

enum SyntaxHighlighter {
    /// Larger files skip highlighting: full-document regex passes would stall typing.
    static let maxLength = 400_000

    /// Tokenizes `text` into consecutive style runs. Pure and thread-safe (regexes are), so it
    /// runs off the main thread on an immutable snapshot while the user keeps typing.
    nonisolated static func runs(for language: Language, in text: NSString) -> [StyleRun] {
        let length = text.length
        let full = NSRange(location: 0, length: length)
        guard length > 0 else { return [] }
        guard length <= maxLength else { return [StyleRun(range: full, token: nil)] }
        // One style code per UTF-16 unit (0 = plain); later rules overwrite earlier ones.
        var styles = [UInt8](repeating: 0, count: length)
        let string = text as String
        styles.withUnsafeMutableBufferPointer { buffer in
            for (regex, rule) in language.rules {
                regex.enumerateMatches(in: string, range: full) { match, _, _ in
                    guard let match, match.range.length > 0 else { return }
                    let token = rule == .stringOrComment ? resolve(match, in: text) : rule
                    let range = match.range
                    buffer[range.location..<NSMaxRange(range)].update(repeating: token.rawValue + 1)
                }
            }
        }
        var runs: [StyleRun] = []
        var start = 0
        for index in 1...length where index == length || styles[index] != styles[start] {
            let code = styles[start]
            runs.append(StyleRun(range: NSRange(location: start, length: index - start),
                                 token: code == 0 ? nil : SyntaxToken(rawValue: code - 1)))
            start = index
        }
        return runs
    }

    /// Indices of `new` runs that differ from the previously applied `old` ones: everything
    /// between the common prefix and the common suffix (shifted by the length change). An edit
    /// always changes the run containing it, so runs outside this window kept their styling.
    static func changedRange(old: [StyleRun]?, new: [StyleRun]) -> Range<Int> {
        guard let old, !old.isEmpty else { return 0..<new.count }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        let delta = (new.last.map { NSMaxRange($0.range) } ?? 0) - NSMaxRange(old[old.count - 1].range)
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix {
            let before = old[old.count - 1 - suffix], after = new[new.count - 1 - suffix]
            guard before.token == after.token, before.range.length == after.range.length,
                  before.range.location + delta == after.range.location else { break }
            suffix += 1
        }
        return prefix..<(new.count - suffix)
    }

    /// Applies runs to the storage. Unless `force`, runs whose characters already carry the
    /// right font and color are skipped: attributes move with the text as the user types, so
    /// only the few runs around an edit actually change, and untouched text keeps its layout.
    static func apply(_ runs: ArraySlice<StyleRun>, to storage: NSTextStorage, font: NSFont, force: Bool) {
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let paragraph = EditorSettings.paragraphStyle(for: font)
        storage.beginEditing()
        for run in runs where NSMaxRange(run.range) <= storage.length {
            let color = run.token?.color ?? Theme.editorForeground
            let runFont = run.token.map { $0.isItalic ? italic : ($0.isBold ? bold : font) } ?? font
            if !force {
                var matches = true
                storage.enumerateAttributes(in: run.range, options: .longestEffectiveRangeNotRequired) { attributes, _, stop in
                    if (attributes[.foregroundColor] as? NSColor) != color || (attributes[.font] as? NSFont) != runFont {
                        matches = false
                        stop.pointee = true
                    }
                }
                if matches { continue }
            }
            storage.setAttributes([.font: runFont, .foregroundColor: color, .paragraphStyle: paragraph], range: run.range)
        }
        storage.endEditing()
    }

    /// Each strings-and-comments match is a comment when it opens with a comment marker
    /// (Python docstrings count as comments, as in Dracula).
    nonisolated private static func resolve(_ match: NSTextCheckingResult, in text: NSString) -> SyntaxToken {
        let head = text.substring(with: NSRange(location: match.range.location, length: min(3, match.range.length)))
        let commentMarkers = ["//", "/*", "#", "--", "\"\"\"", "'''"]
        return commentMarkers.contains { head.hasPrefix($0) } ? .comment : .string
    }
}
