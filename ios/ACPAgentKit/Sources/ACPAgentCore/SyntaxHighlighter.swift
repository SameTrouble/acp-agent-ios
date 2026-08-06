import Foundation

// MARK: - Token model

public enum SyntaxTokenKind: Equatable, Sendable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
}

public struct SyntaxToken: Equatable, Sendable {
    public let kind: SyntaxTokenKind
    public let range: Range<String.Index>

    init(kind: SyntaxTokenKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}

/// Language of a file being diffed, detected from the file path. The
/// highlighter is deliberately lightweight — keyword/string/comment/number
/// plus capitalized-type and call-site tokens — enough to read a diff
/// without pulling in a full parser.
public enum SyntaxLanguage: String, Codable, Equatable, Sendable, CaseIterable {
    case swift
    case typescript
    case python
    case go
    case java
    case kotlin
    case c
    case cpp
    case rust
    case ruby
    case shell
    case json
    case yaml
    case css
    case html
    case markdown
    case plain

    public static func detect(from path: String) -> SyntaxLanguage {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": return .typescript
        case "py", "pyi": return .python
        case "go": return .go
        case "java": return .java
        case "kt", "kts": return .kotlin
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": return .cpp
        case "rs": return .rust
        case "rb": return .ruby
        case "sh", "bash", "zsh": return .shell
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "css": return .css
        case "html", "htm": return .html
        case "md", "markdown": return .markdown
        default: return .plain
        }
    }
}

// MARK: - Highlighter

public enum SyntaxHighlighter {
    private struct Spec {
        let comments: String
        let strings: String
        let keywords: String
        let types: Bool
        let functions: Bool
        let numbers: Bool
    }

    private static let doubleQuoted = #""(?:\\.|[^"\\])*""#
    private static let singleQuoted = #"'(?:\\.|[^'\\])*'"#
    private static let backtickQuoted = #"`(?:\\.|[^`\\])*`"#
    private static let lineSlashComment = #"//[^\n]*"#
    private static let blockSlashComment = #"/\*.*?\*/"#
    private static let hashComment = #"#[^\n]*"#
    private static let htmlComment = #"<!--.*?-->"#
    private static let typePattern = #"\b[A-Z][A-Za-z0-9_]*\b"#
    private static let functionPattern = #"\b[a-z_][A-Za-z0-9_]*\b(?=\s*\()"#
    private static let numberPattern = #"\b(?:(?:0[xX][0-9a-fA-F]+)|(?:\d[\d_]*(?:\.[\d_]+)?(?:[eE][+-]?\d+)?))\b"#

    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard language != .plain, !text.isEmpty, let regex = RegexCache.shared.regex(for: language, build: { makeRegex(for: language) }) else { return [] }
        let nsText = text as NSString
        var result: [SyntaxToken] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) { match, _, _ in
            guard let match else { return }
            for (index, kind) in tokenKinds(for: language).enumerated() {
                let range = match.range(at: index + 1)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { continue }
                result.append(SyntaxToken(kind: kind, range: swiftRange))
                return
            }
        }
        return result
    }

    /// Thread-safe cache of compiled regexes keyed by language; the build
    /// closure re-creates one only on a miss.
    private final class RegexCache: @unchecked Sendable {
        static let shared = RegexCache()

        private var storage: [SyntaxLanguage: NSRegularExpression] = [:]
        private let lock = NSLock()

        func regex(for language: SyntaxLanguage, build: () -> NSRegularExpression?) -> NSRegularExpression? {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[language] { return cached }
            let built = build()
            if let built { storage[language] = built }
            return built
        }
    }

    private static func makeRegex(for language: SyntaxLanguage) -> NSRegularExpression? {
        guard let spec = spec(for: language) else { return nil }

        var parts: [(kind: SyntaxTokenKind, pattern: String)] = []
        if !spec.comments.isEmpty { parts.append((.comment, spec.comments)) }
        if !spec.strings.isEmpty { parts.append((.string, spec.strings)) }
        if !spec.keywords.isEmpty { parts.append((.keyword, spec.keywords)) }
        if spec.types { parts.append((.type, typePattern)) }
        if spec.functions { parts.append((.function, functionPattern)) }
        if spec.numbers { parts.append((.number, numberPattern)) }

        let pattern = parts.map { "(\($0.pattern))" }.joined(separator: "|")
        return try? NSRegularExpression(pattern: pattern)
    }

    private static func tokenKinds(for language: SyntaxLanguage) -> [SyntaxTokenKind] {
        guard let spec = spec(for: language) else { return [] }
        var kinds: [SyntaxTokenKind] = []
        if !spec.comments.isEmpty { kinds.append(.comment) }
        if !spec.strings.isEmpty { kinds.append(.string) }
        if !spec.keywords.isEmpty { kinds.append(.keyword) }
        if spec.types { kinds.append(.type) }
        if spec.functions { kinds.append(.function) }
        if spec.numbers { kinds.append(.number) }
        return kinds
    }

    private static func keywordPattern(_ words: [String]) -> String {
        let joined = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return "\\b(?:\(joined))\\b"
    }

    private static func spec(for language: SyntaxLanguage) -> Spec? {
        let slash = "\(lineSlashComment)|\(blockSlashComment)"
        switch language {
        case .swift:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "let", "var", "func", "if", "else", "guard", "for", "while", "repeat", "switch",
                "case", "default", "break", "continue", "return", "in", "import", "class", "struct",
                "enum", "protocol", "extension", "public", "private", "fileprivate", "internal",
                "open", "static", "final", "override", "init", "deinit", "throws", "throw", "try",
                "catch", "async", "await", "actor", "mutating", "nonmutating", "where",
                "associatedtype", "typealias", "indirect", "lazy", "weak", "unowned", "required",
                "convenience", "defer", "do", "fallthrough", "is", "as", "self", "super", "nil",
                "true", "false", "some", "any", "get", "set", "willSet", "didSet", "subscript",
                "operator", "precedencegroup",
            ]), types: true, functions: true, numbers: true)
        case .typescript:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)|\(backtickQuoted)", keywords: keywordPattern([
                "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
                "switch", "case", "default", "break", "continue", "new", "class", "interface",
                "type", "enum", "extends", "implements", "import", "export", "from", "async",
                "await", "try", "catch", "finally", "throw", "yield", "typeof", "instanceof", "in",
                "of", "this", "super", "null", "undefined", "true", "false", "void", "delete",
                "static", "get", "set", "readonly", "abstract", "public", "private", "protected",
                "keyof", "satisfies", "as", "is", "namespace", "declare", "global", "with",
                "debugger",
            ]), types: true, functions: true, numbers: true)
        case .python:
            return Spec(comments: hashComment, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                "as", "try", "except", "finally", "raise", "with", "lambda", "pass", "break",
                "continue", "global", "nonlocal", "yield", "async", "await", "del", "assert",
                "True", "False", "None", "and", "or", "not", "in", "is", "match", "case", "self",
                "cls",
            ]), types: true, functions: true, numbers: true)
        case .go:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)|\(backtickQuoted)", keywords: keywordPattern([
                "func", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range",
                "return", "import", "package", "var", "const", "go", "defer", "select", "switch",
                "case", "default", "break", "continue", "fallthrough", "goto", "true", "false",
                "nil", "iota", "append", "make", "new", "len", "cap", "panic", "recover", "error",
                "string", "int", "int64", "uint", "byte", "rune", "bool", "float64", "float32",
                "any",
            ]), types: true, functions: true, numbers: true)
        case .java:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "public", "private", "protected", "class", "interface", "enum", "extends",
                "implements", "import", "package", "static", "final", "abstract", "void", "int",
                "long", "double", "float", "boolean", "char", "byte", "short", "new", "return",
                "if", "else", "for", "while", "do", "switch", "case", "default", "break",
                "continue", "try", "catch", "finally", "throw", "throws", "this", "super", "null",
                "true", "false", "synchronized", "volatile", "transient", "native", "strictfp",
                "instanceof", "record", "sealed", "permits", "yield", "var",
            ]), types: true, functions: true, numbers: true)
        case .kotlin:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "fun", "val", "var", "class", "object", "interface", "enum", "data", "sealed",
                "open", "override", "abstract", "final", "public", "private", "protected",
                "internal", "companion", "import", "package", "return", "if", "else", "when",
                "for", "while", "do", "try", "catch", "finally", "throw", "this", "super", "null",
                "true", "false", "is", "in", "as", "by", "lazy", "lateinit", "vararg", "inline",
                "noinline", "crossinline", "suspend", "operator", "infix", "tailrec", "reified",
                "where", "typealias", "init", "constructor", "get", "set",
            ]), types: true, functions: true, numbers: true)
        case .c:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "if", "else", "for", "while", "do", "switch", "case", "default", "break",
                "continue", "return", "struct", "union", "enum", "typedef", "static", "extern",
                "register", "volatile", "const", "unsigned", "signed", "char", "int", "float",
                "double", "long", "short", "void", "sizeof", "goto", "true", "false",
            ]), types: true, functions: true, numbers: true)
        case .cpp:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "if", "else", "for", "while", "do", "switch", "case", "default", "break",
                "continue", "return", "struct", "union", "enum", "typedef", "static", "extern",
                "register", "volatile", "const", "unsigned", "signed", "char", "int", "float",
                "double", "long", "short", "void", "sizeof", "goto", "true", "false", "class",
                "namespace", "template", "typename", "public", "private", "protected", "virtual",
                "override", "final", "new", "delete", "this", "nullptr", "using", "auto",
                "constexpr", "explicit", "friend", "inline", "operator", "try", "catch", "throw",
                "noexcept", "static_cast", "dynamic_cast", "const_cast", "reinterpret_cast",
            ]), types: true, functions: true, numbers: true)
        case .rust:
            return Spec(comments: slash, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "mod",
                "use", "pub", "crate", "super", "self", "if", "else", "match", "for", "while",
                "loop", "return", "break", "continue", "where", "as", "in", "type", "async",
                "await", "move", "ref", "unsafe", "extern", "dyn", "true", "false", "None",
                "Some", "Ok", "Err", "String", "Vec", "Option", "Result", "Box", "u8", "u16",
                "u32", "u64", "i8", "i16", "i32", "i64", "f32", "f64", "usize", "isize", "bool",
                "char", "str", "macro_rules",
            ]), types: true, functions: true, numbers: true)
        case .ruby:
            return Spec(comments: hashComment, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "def", "class", "module", "if", "elsif", "else", "unless", "case", "when",
                "then", "for", "while", "until", "do", "end", "return", "yield", "require",
                "include", "extend", "attr_accessor", "attr_reader", "attr_writer", "private",
                "public", "protected", "begin", "rescue", "ensure", "raise", "throw", "catch",
                "lambda", "proc", "true", "false", "nil", "self", "super", "and", "or", "not",
                "new",
            ]), types: true, functions: true, numbers: true)
        case .shell:
            return Spec(comments: hashComment, strings: "\(doubleQuoted)|\(singleQuoted)|\(backtickQuoted)", keywords: keywordPattern([
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                "case", "esac", "function", "in", "return", "exit", "export", "local",
                "readonly", "source", "alias", "unset", "set", "shift", "trap", "echo",
                "printf", "true", "false", "cd", "pwd", "ls", "mkdir", "rm", "cp", "mv", "grep",
                "sed", "awk", "cat", "touch", "chmod", "chown", "sudo", "git", "npm", "bun",
                "yarn", "pnpm", "curl", "wget", "find", "xargs", "tar", "zip", "unzip", "head",
                "tail", "cut", "sort", "uniq", "wc", "tee", "which", "type",
            ]), types: false, functions: false, numbers: true)
        case .json:
            return Spec(comments: "", strings: doubleQuoted, keywords: keywordPattern([
                "true", "false", "null",
            ]), types: false, functions: false, numbers: true)
        case .yaml:
            return Spec(comments: hashComment, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "true", "false", "null", "yes", "no", "on", "off",
            ]), types: false, functions: false, numbers: true)
        case .css:
            return Spec(comments: blockSlashComment, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: keywordPattern([
                "color", "background", "background-color", "margin", "padding", "border",
                "display", "position", "top", "right", "bottom", "left", "width", "height",
                "font", "font-size", "font-family", "font-weight", "text-align", "overflow",
                "z-index", "opacity", "flex", "grid", "align-items", "justify-content", "gap",
                "max-width", "min-width", "cursor", "transition", "transform", "box-shadow",
                "border-radius",
            ]), types: false, functions: false, numbers: true)
        case .html:
            return Spec(comments: htmlComment, strings: "\(doubleQuoted)|\(singleQuoted)", keywords: "", types: false, functions: false, numbers: false)
        case .markdown:
            return Spec(comments: "", strings: backtickQuoted, keywords: "(?:^|\\n)#{1,6}\\s", types: false, functions: false, numbers: false)
        case .plain:
            return nil
        }
    }
}
