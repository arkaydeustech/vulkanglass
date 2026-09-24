import AppKit
import Foundation

/// Lightweight fenced-code highlighter for live preview.
enum CodeHighlight {
    enum Kind: Equatable {
        case keyword
        case ident
        case function
        case string
        case comment
        case number
        case `operator`
    }

    static func displayName(for language: String) -> String {
        let key = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "py", "python": return "Python"
        case "js", "javascript": return "JavaScript"
        case "ts", "typescript": return "TypeScript"
        case "swift": return "Swift"
        case "json": return "JSON"
        case "sh", "bash", "zsh", "shell": return "Bash"
        case "html", "htm": return "HTML"
        case "css": return "CSS"
        case "sql": return "SQL"
        case "go", "golang": return "Go"
        case "rs", "rust": return "Rust"
        case "yml", "yaml": return "YAML"
        case "md", "markdown": return "Markdown"
        case "c": return "C"
        case "cpp", "c++", "cc": return "C++"
        case "objc", "objective-c", "objectivec": return "Objective-C"
        case "java": return "Java"
        case "kt", "kotlin": return "Kotlin"
        case "rb", "ruby": return "Ruby"
        case "php": return "PHP"
        case "r": return "R"
        case "": return ""
        default:
            return key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// Fill behind a fenced code block in both the editor and reading view.
    static func blockFill(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
            : NSColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    }

    /// Colour of the language label drawn in a code block's corner.
    static func labelColor(dark: Bool) -> NSColor {
        dark
            ? NSColor(red: 0.52, green: 0.54, blue: 0.56, alpha: 1)
            : NSColor(red: 0.48, green: 0.50, blue: 0.52, alpha: 1)
    }

    static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    static func color(for kind: Kind, dark: Bool) -> NSColor {
        switch kind {
        case .keyword:
            return dark
                ? NSColor(red: 0.95, green: 0.45, blue: 0.70, alpha: 1)
                : NSColor(red: 0.78, green: 0.18, blue: 0.48, alpha: 1)
        case .ident:
            return dark
                ? NSColor(red: 0.45, green: 0.82, blue: 0.90, alpha: 1)
                : NSColor(red: 0.10, green: 0.45, blue: 0.62, alpha: 1)
        case .function:
            return dark
                ? NSColor(red: 0.40, green: 0.72, blue: 0.95, alpha: 1)
                : NSColor(red: 0.12, green: 0.38, blue: 0.72, alpha: 1)
        case .string:
            return dark
                ? NSColor(red: 0.75, green: 0.82, blue: 0.45, alpha: 1)
                : NSColor(red: 0.42, green: 0.52, blue: 0.12, alpha: 1)
        case .comment:
            return dark
                ? NSColor(red: 0.48, green: 0.50, blue: 0.52, alpha: 1)
                : NSColor(red: 0.52, green: 0.54, blue: 0.56, alpha: 1)
        case .number:
            return dark
                ? NSColor(red: 0.72, green: 0.58, blue: 0.92, alpha: 1)
                : NSColor(red: 0.48, green: 0.28, blue: 0.72, alpha: 1)
        case .operator:
            return dark
                ? NSColor(red: 0.95, green: 0.55, blue: 0.70, alpha: 1)
                : NSColor(red: 0.78, green: 0.22, blue: 0.48, alpha: 1)
        }
    }

    static func spans(in code: String, language: String) -> [(NSRange, Kind)] {
        let ns = code as NSString
        let family = Family.of(language)
        let words = keywords(for: language)
        var i = 0
        var result: [(NSRange, Kind)] = []
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 32 || ch == 9 || ch == 10 || ch == 13 {
                i += 1
                continue
            }
            if let range = scanComment(in: ns, from: i, family: family) {
                result.append((range, .comment))
                i = NSMaxRange(range)
                continue
            }
            if let range = scanString(in: ns, from: i, family: family) {
                result.append((range, .string))
                i = NSMaxRange(range)
                continue
            }
            if let range = scanNumber(in: ns, from: i) {
                result.append((range, .number))
                i = NSMaxRange(range)
                continue
            }
            if let range = scanIdent(in: ns, from: i) {
                let word = ns.substring(with: range)
                let next = skipSpace(in: ns, from: NSMaxRange(range))
                let call = next < ns.length && ns.character(at: next) == 40
                let kind: Kind
                if words.contains(word) || (family == .sql && words.contains(word.lowercased())) {
                    kind = .keyword
                } else if call {
                    kind = .function
                } else {
                    kind = .ident
                }
                result.append((range, kind))
                i = NSMaxRange(range)
                continue
            }
            if let range = scanOperator(in: ns, from: i) {
                result.append((range, .operator))
                i = NSMaxRange(range)
                continue
            }
            i += 1
        }
        return result
    }

    // MARK: - Language families

    private enum Family {
        case python, clike, hash, sql, json, html, generic

        static func of(_ language: String) -> Family {
            switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "py", "python": return .python
            case "js", "javascript", "ts", "typescript", "swift", "go", "golang",
                 "rs", "rust", "java", "kt", "kotlin", "c", "cpp", "c++", "cc",
                 "objc", "objective-c", "objectivec", "css", "php":
                return .clike
            case "sh", "bash", "zsh", "shell", "yml", "yaml", "rb", "ruby", "r", "perl":
                return .hash
            case "sql": return .sql
            case "json": return .json
            case "html", "htm", "xml", "svg": return .html
            default: return .generic
            }
        }
    }

    private static func keywords(for language: String) -> Set<String> {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "py", "python":
            return [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass",
                "raise", "return", "True", "try", "while", "with", "yield"
            ]
        case "js", "javascript", "ts", "typescript":
            return [
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                "finally", "for", "from", "function", "if", "import", "in", "instanceof", "let",
                "new", "null", "of", "return", "static", "super", "switch", "this", "throw",
                "true", "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
                "type", "interface", "enum", "implements", "private", "protected", "public"
            ]
        case "swift":
            return [
                "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
                "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "internal",
                "let", "nil", "operator", "override", "private", "protocol", "public", "repeat",
                "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try",
                "typealias", "var", "where", "while", "some", "any", "actor"
            ]
        case "go", "golang":
            return [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var"
            ]
        case "rs", "rust":
            return [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop",
                "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
                "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"
            ]
        case "java", "kt", "kotlin":
            return [
                "abstract", "as", "break", "case", "catch", "class", "const", "continue",
                "default", "do", "else", "enum", "false", "final", "finally", "for", "fun",
                "if", "import", "in", "interface", "is", "new", "null", "object", "package",
                "private", "protected", "public", "return", "static", "super", "this", "throw",
                "true", "try", "typealias", "val", "var", "void", "while"
            ]
        case "c", "cpp", "c++", "cc", "objc", "objective-c", "objectivec":
            return [
                "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
                "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
                "register", "return", "short", "signed", "sizeof", "static", "struct", "switch",
                "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "class",
                "namespace", "new", "delete", "template", "this", "true", "false", "nil"
            ]
        case "sql":
            return [
                "add", "all", "alter", "and", "as", "asc", "between", "by", "case", "create",
                "delete", "desc", "distinct", "drop", "else", "end", "exists", "from", "group",
                "having", "in", "inner", "insert", "into", "is", "join", "left", "like", "limit",
                "not", "null", "on", "or", "order", "outer", "right", "select", "set", "table",
                "then", "union", "update", "values", "when", "where"
            ]
        case "json":
            return ["true", "false", "null"]
        case "rb", "ruby":
            return [
                "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif",
                "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
                "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true",
                "undef", "unless", "until", "when", "while", "yield"
            ]
        case "sh", "bash", "zsh", "shell":
            return [
                "alias", "break", "case", "continue", "do", "done", "elif", "else", "esac",
                "export", "fi", "for", "function", "if", "in", "local", "return", "select",
                "then", "until", "while"
            ]
        default:
            return []
        }
    }

    // MARK: - Scanners

    private static func scanComment(in ns: NSString, from i: Int, family: Family) -> NSRange? {
        switch family {
        case .python, .hash:
            guard ns.character(at: i) == 35 else { return nil }
            return toLineEnd(in: ns, from: i)
        case .sql:
            if i + 1 < ns.length, ns.character(at: i) == 45, ns.character(at: i + 1) == 45 {
                return toLineEnd(in: ns, from: i)
            }
            return nil
        case .clike, .generic:
            if i + 1 < ns.length, ns.character(at: i) == 47, ns.character(at: i + 1) == 47 {
                return toLineEnd(in: ns, from: i)
            }
            if i + 1 < ns.length, ns.character(at: i) == 47, ns.character(at: i + 1) == 42 {
                var j = i + 2
                while j + 1 < ns.length {
                    if ns.character(at: j) == 42, ns.character(at: j + 1) == 47 {
                        return NSRange(location: i, length: j + 2 - i)
                    }
                    j += 1
                }
                return NSRange(location: i, length: ns.length - i)
            }
            return nil
        case .html:
            if i + 3 < ns.length,
               ns.character(at: i) == 60,
               ns.character(at: i + 1) == 33,
               ns.character(at: i + 2) == 45,
               ns.character(at: i + 3) == 45
            {
                var j = i + 4
                while j + 2 < ns.length {
                    if ns.character(at: j) == 45, ns.character(at: j + 1) == 45, ns.character(at: j + 2) == 62 {
                        return NSRange(location: i, length: j + 3 - i)
                    }
                    j += 1
                }
                return NSRange(location: i, length: ns.length - i)
            }
            return nil
        case .json:
            return nil
        }
    }

    private static func scanString(in ns: NSString, from i: Int, family: Family) -> NSRange? {
        if family == .python, let triple = scanPythonTriple(in: ns, from: i) {
            return triple
        }
        let ch = ns.character(at: i)
        let quote: unichar
        if ch == 34 || ch == 39 {
            quote = ch
        } else if family == .clike, ch == 96 {
            quote = ch
        } else {
            return nil
        }
        var j = i + 1
        while j < ns.length {
            let cur = ns.character(at: j)
            if cur == 92, j + 1 < ns.length {
                j += 2
                continue
            }
            if cur == 10 || cur == 13 { break }
            if cur == quote {
                return NSRange(location: i, length: j + 1 - i)
            }
            j += 1
        }
        return NSRange(location: i, length: j - i)
    }

    private static func scanPythonTriple(in ns: NSString, from i: Int) -> NSRange? {
        guard i + 2 < ns.length else { return nil }
        let a = ns.character(at: i)
        guard a == 34 || a == 39 else { return nil }
        guard ns.character(at: i + 1) == a, ns.character(at: i + 2) == a else { return nil }
        var j = i + 3
        while j + 2 < ns.length {
            if ns.character(at: j) == a, ns.character(at: j + 1) == a, ns.character(at: j + 2) == a {
                return NSRange(location: i, length: j + 3 - i)
            }
            if ns.character(at: j) == 92 { j += 1 }
            j += 1
        }
        return NSRange(location: i, length: ns.length - i)
    }

    private static func scanNumber(in ns: NSString, from i: Int) -> NSRange? {
        let ch = ns.character(at: i)
        if ch == 48, i + 1 < ns.length {
            let next = ns.character(at: i + 1)
            if next == 120 || next == 88 {
                var j = i + 2
                while j < ns.length, isHex(ns.character(at: j)) { j += 1 }
                if j > i + 2 { return NSRange(location: i, length: j - i) }
            }
        }
        guard isDigit(ch) else { return nil }
        var j = i + 1
        var seenDot = false
        while j < ns.length {
            let cur = ns.character(at: j)
            if isDigit(cur) {
                j += 1
            } else if cur == 46, !seenDot {
                seenDot = true
                j += 1
            } else {
                break
            }
        }
        return NSRange(location: i, length: j - i)
    }

    private static func scanIdent(in ns: NSString, from i: Int) -> NSRange? {
        let ch = ns.character(at: i)
        guard isIdentStart(ch) else { return nil }
        var j = i + 1
        while j < ns.length, isIdentPart(ns.character(at: j)) { j += 1 }
        return NSRange(location: i, length: j - i)
    }

    private static func scanOperator(in ns: NSString, from i: Int) -> NSRange? {
        let ch = ns.character(at: i)
        let ops: Set<unichar> = [
            33, 37, 38, 42, 43, 44, 45, 46, 47, 58, 59, 60, 61, 62, 63, 94, 124, 126
        ]
        guard ops.contains(ch) else { return nil }
        var j = i + 1
        while j < ns.length, ops.contains(ns.character(at: j)) { j += 1 }
        return NSRange(location: i, length: j - i)
    }

    private static func toLineEnd(in ns: NSString, from i: Int) -> NSRange {
        var j = i
        while j < ns.length {
            let ch = ns.character(at: j)
            if ch == 10 || ch == 13 { break }
            j += 1
        }
        return NSRange(location: i, length: j - i)
    }

    private static func skipSpace(in ns: NSString, from i: Int) -> Int {
        var j = i
        while j < ns.length {
            let ch = ns.character(at: j)
            if ch == 32 || ch == 9 { j += 1 } else { break }
        }
        return j
    }

    private static func isDigit(_ ch: unichar) -> Bool { ch >= 48 && ch <= 57 }
    private static func isHex(_ ch: unichar) -> Bool {
        isDigit(ch) || (ch >= 65 && ch <= 70) || (ch >= 97 && ch <= 102)
    }
    private static func isIdentStart(_ ch: unichar) -> Bool {
        (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95
    }
    private static func isIdentPart(_ ch: unichar) -> Bool { isIdentStart(ch) || isDigit(ch) }
}
