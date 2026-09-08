import Foundation

/// Conservative, dialect-agnostic SQL formatter (ROADMAP M3 查询格式化),
/// shared by the three SQL engines. Deliberately self-written and
/// conservative: no third-party dependency, and layout is a pure re-spacing
/// of the token stream.
///
/// Safety contract: token content is never altered — string literals
/// (single/double quotes, `''` and backslash escapes, PostgreSQL
/// dollar-quoted bodies), quoted identifiers (""…"" / `…`), line and block
/// comments, numbers, and operators all cross verbatim; only whitespace is
/// re-laid out. As a hard net, `format` re-tokenizes its own output and
/// falls back to the verbatim input when the token stream differs, so a
/// formatter gap can never corrupt a query — it just leaves it unformatted.
enum SQLFormatter {
    /// One lexical token; `text` is always the verbatim source slice.
    struct Token: Equatable {
        enum Kind: Equatable {
            case word, string, quotedIdentifier, number, comment, symbol
        }
        let kind: Kind
        let text: String
    }

    // MARK: Tokenizer

    /// Splits SQL into verbatim tokens, dropping whitespace. Unterminated
    /// strings/comments/dollar-quotes run to the end of input as one token —
    /// the layout never invents a terminator.
    static func tokenize(_ sql: String) -> [Token] {
        var tokens: [Token] = []
        var index = sql.startIndex

        func peek(_ i: String.Index) -> Character? {
            let next = sql.index(after: i)
            return next < sql.endIndex ? sql[next] : nil
        }

        while index < sql.endIndex {
            let char = sql[index]

            if char.isWhitespace {
                index = sql.index(after: index)
                continue
            }

            // Line comment: to end of line (newline excluded).
            if char == "-", peek(index) == "-" {
                let start = index
                while index < sql.endIndex, sql[index] != "\n" {
                    index = sql.index(after: index)
                }
                tokens.append(Token(kind: .comment, text: String(sql[start..<index])))
                continue
            }

            // Block comment: to the first */ or end of input.
            if char == "/", peek(index) == "*" {
                let start = index
                index = sql.index(after: index)
                index = sql.index(after: index)
                while index < sql.endIndex {
                    if sql[index] == "*", peek(index) == "/" {
                        index = sql.index(after: index)
                        index = sql.index(after: index)
                        break
                    }
                    index = sql.index(after: index)
                }
                tokens.append(Token(kind: .comment, text: String(sql[start..<index])))
                continue
            }

            // String literal / quoted identifier: doubled-quote escape, and
            // backslash escape for MySQL-style '…\'…' and `…\`…`.
            if char == "'" || char == "\"" || char == "`" {
                let kind: Token.Kind = char == "'" ? .string : .quotedIdentifier
                let start = index
                index = sql.index(after: index)
                while index < sql.endIndex {
                    let current = sql[index]
                    if current == "\\" {
                        index = sql.index(after: index)
                        if index < sql.endIndex { index = sql.index(after: index) }
                        continue
                    }
                    if current == char {
                        let next = sql.index(after: index)
                        if next < sql.endIndex, sql[next] == char {
                            index = sql.index(after: next)
                            continue
                        }
                        index = next
                        break
                    }
                    index = sql.index(after: index)
                }
                tokens.append(Token(kind: kind, text: String(sql[start..<index])))
                continue
            }

            // PostgreSQL dollar-quoted string: $tag$…$tag$; an unterminated
            // body runs to the end. A bare $ (or $1 parameter) is a symbol.
            if char == "$" {
                var scan = sql.index(after: index)
                var tag = ""
                while scan < sql.endIndex,
                      sql[scan].isASCII, sql[scan].isLetter || sql[scan].isNumber || sql[scan] == "_" {
                    tag.append(sql[scan])
                    scan = sql.index(after: scan)
                }
                if scan < sql.endIndex, sql[scan] == "$" {
                    let delimiter = "$\(tag)$"
                    let start = index
                    index = sql.index(after: scan)
                    if let close = sql[index...].range(of: delimiter) {
                        index = close.upperBound
                    } else {
                        index = sql.endIndex
                    }
                    tokens.append(Token(kind: .string, text: String(sql[start..<index])))
                    continue
                }
                tokens.append(Token(kind: .symbol, text: "$"))
                index = sql.index(after: index)
                continue
            }

            // Number: digits with optional fraction/exponent, or hex 0x….
            if char.isASCII, char.isNumber {
                let start = index
                if char == "0", let next = peek(index), next == "x" || next == "X" {
                    index = sql.index(after: index)
                    index = sql.index(after: index)
                    while index < sql.endIndex, sql[index].isASCII, sql[index].isHexDigit {
                        index = sql.index(after: index)
                    }
                } else {
                    while index < sql.endIndex, sql[index].isASCII, sql[index].isNumber {
                        index = sql.index(after: index)
                    }
                    if index < sql.endIndex, sql[index] == ".",
                       let next = peek(index), next.isASCII, next.isNumber {
                        index = sql.index(after: index)
                        while index < sql.endIndex, sql[index].isASCII, sql[index].isNumber {
                            index = sql.index(after: index)
                        }
                    }
                    if index < sql.endIndex, sql[index] == "e" || sql[index] == "E" {
                        var scan = sql.index(after: index)
                        if scan < sql.endIndex, sql[scan] == "+" || sql[scan] == "-" {
                            scan = sql.index(after: scan)
                        }
                        if scan < sql.endIndex, sql[scan].isASCII, sql[scan].isNumber {
                            index = scan
                            while index < sql.endIndex, sql[index].isASCII, sql[index].isNumber {
                                index = sql.index(after: index)
                            }
                        }
                    }
                }
                tokens.append(Token(kind: .number, text: String(sql[start..<index])))
                continue
            }

            // Word: identifier or keyword ($ allowed mid-word for PG).
            if char.isLetter || char == "_" {
                let start = index
                while index < sql.endIndex,
                      sql[index].isLetter || sql[index].isNumber || sql[index] == "_" || sql[index] == "$" {
                    index = sql.index(after: index)
                }
                tokens.append(Token(kind: .word, text: String(sql[start..<index])))
                continue
            }

            // Multi-char operators (longest first), then any single char.
            let rest = sql[index...]
            let matched = Self.multiCharOperators.first { rest.hasPrefix($0) }
            let text = matched ?? String(char)
            tokens.append(Token(kind: .symbol, text: text))
            index = sql.index(index, offsetBy: text.count)
        }
        return tokens
    }

    private static let multiCharOperators = [
        "->>", "#>>", "::", "->", "#>", ">=", "<=", "<>", "!=", "||", ":=", "=>", "!~*",
        "!~", "~*", "@>", "<@", "&&", "<<", ">>",
    ]

    // MARK: Layout

    /// Words that start a new line at the current indent.
    private static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "RETURNING",
        "VALUES", "SET", "UNION", "INTERSECT", "EXCEPT",
        "GROUP", "ORDER", "INSERT", "UPDATE", "DELETE", "WITH",
    ]

    /// JOIN qualifiers; they break only when a JOIN follows directly.
    private static let joinModifiers: Set<String> = [
        "LEFT", "RIGHT", "FULL", "INNER", "CROSS", "OUTER", "NATURAL",
    ]

    /// Clause contexts whose comma lists break one item per line.
    private static let commaBreakingClauses: Set<String> = ["SELECT", "GROUP", "ORDER"]

    /// Keywords that keep a space before "(" (IN (…), FROM (… derived
    /// tables); a plain word before "(" is a function call and binds tight.
    private static let parenSpaceKeywords: Set<String> = [
        "IN", "EXISTS", "VALUES", "NOT", "ANY", "ALL", "ARRAY",
        "FROM", "JOIN", "ON", "TABLE",
    ]

    private struct Frame {
        var indent: Int
        let isSubquery: Bool
        var clause: String
    }

    /// One output line under construction.
    private struct Writer {
        private(set) var text = ""
        private(set) var lineEmpty = true

        mutating func newline(indent: Int) {
            while text.last == " " { text.removeLast() }
            if !text.isEmpty, text.last != "\n" { text.append("\n") }
            text.append(String(repeating: " ", count: indent * 2))
            lineEmpty = true
        }

        mutating func space() {
            if !lineEmpty, text.last != " " { text.append(" ") }
        }

        mutating func write(_ value: String) {
            text.append(value)
            lineEmpty = false
        }
    }

    /// Re-lays the token stream out: clause keywords break at the frame
    /// indent, AND/OR one level deeper, SELECT/GROUP/ORDER comma lists one
    /// item per line, subquery parentheses get their own indented frame.
    /// The result is verified against the tokenizer before it is returned;
    /// any mismatch falls back to the verbatim input.
    static func format(_ sql: String) -> String {
        let tokens = tokenize(sql)
        // Nothing but whitespace or comments: leave the input alone.
        guard tokens.contains(where: { $0.kind != .comment }) else { return sql }

        var writer = Writer()
        var frames: [Frame] = [Frame(indent: 0, isSubquery: false, clause: "")]
        var previous: Token?
        var previousWord = ""
        var forceNewline = false

        func nextSignificant(after index: Int) -> Token? {
            var scan = index + 1
            while scan < tokens.count {
                if tokens[scan].kind != .comment { return tokens[scan] }
                scan += 1
            }
            return nil
        }

        for index in tokens.indices {
            let token = tokens[index]
            let upper = token.kind == .word ? token.text.uppercased() : ""

            switch token.text {
            case "(":
                let next = nextSignificant(after: index)
                let isSubquery = next.map {
                    $0.kind == .word && ["SELECT", "WITH"].contains($0.text.uppercased())
                } ?? false
                if !writer.lineEmpty, let prev = previous, needsSpace(after: prev, before: token) {
                    writer.space()
                }
                writer.write("(")
                let base = frames.last?.indent ?? 0
                frames.append(Frame(
                    indent: isSubquery ? base + 1 : base,
                    isSubquery: isSubquery,
                    clause: ""))
                if isSubquery { writer.newline(indent: base + 1) }
                previous = token
                continue
            case ")":
                let frame = frames.count > 1 ? frames.removeLast() : frames[0]
                if frame.isSubquery {
                    writer.newline(indent: frames.last?.indent ?? 0)
                }
                writer.write(")")
                previous = token
                continue
            case ";":
                writer.write(";")
                frames[frames.count - 1].clause = ""
                writer.newline(indent: 0)
                previous = token
                continue
            case ",":
                writer.write(",")
                if commaBreakingClauses.contains(frames.last?.clause ?? "") {
                    writer.newline(indent: (frames.last?.indent ?? 0) + 1)
                } else {
                    writer.space()
                }
                previous = token
                continue
            default:
                break
            }

            // A line comment swallows the rest of its line: whatever follows
            // must start a fresh line, or it would join the comment.
            if forceNewline {
                writer.newline(indent: frames.last?.indent ?? 0)
                forceNewline = false
            }

            if token.kind == .word {
                let isJoinModifier = joinModifiers.contains(upper)
                    && Self.joinFollows(in: tokens, after: index)
                let isBareJoin = upper == "JOIN" && !joinModifiers.contains(previousWord)
                let isCondition = upper == "AND" || upper == "OR"

                if !writer.lineEmpty {
                    if clauseStarters.contains(upper) || isJoinModifier || isBareJoin {
                        writer.newline(indent: frames.last?.indent ?? 0)
                    } else if isCondition {
                        writer.newline(indent: (frames.last?.indent ?? 0) + 1)
                    } else if let prev = previous, needsSpace(after: prev, before: token) {
                        writer.space()
                    }
                }
                switch upper {
                case "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING":
                    frames[frames.count - 1].clause = upper
                case "JOIN", "ON":
                    frames[frames.count - 1].clause = "JOIN"
                case "UNION", "INTERSECT", "EXCEPT", "VALUES", "SET", "LIMIT", "INSERT", "UPDATE", "DELETE", "WITH":
                    frames[frames.count - 1].clause = ""
                default:
                    break
                }
                previousWord = upper
            } else if token.kind == .comment {
                if !writer.lineEmpty { writer.space() }
                writer.write(token.text)
                if token.text.hasPrefix("--") {
                    forceNewline = true
                } else {
                    writer.space()
                }
                previous = token
                continue
            } else {
                if !writer.lineEmpty, let prev = previous, needsSpace(after: prev, before: token) {
                    writer.space()
                }
                if token.kind != .symbol { previousWord = "" }
            }

            writer.write(token.text)
            previous = token
        }

        let formatted = writer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Safety net: the re-laid text must tokenize to the exact same token
        // stream; otherwise return the input untouched.
        guard !formatted.isEmpty, tokenize(formatted) == tokens else { return sql }
        return formatted
    }

    /// Whether a JOIN keyword follows within the next couple of words
    /// (LEFT OUTER JOIN, CROSS JOIN, …), skipping comments.
    private static func joinFollows(in tokens: [Token], after index: Int) -> Bool {
        var scan = index + 1
        var words = 0
        while scan < tokens.count, words < 3 {
            let token = tokens[scan]
            if token.kind == .comment {
                scan += 1
                continue
            }
            guard token.kind == .word else { return false }
            if token.text.uppercased() == "JOIN" { return true }
            words += 1
            scan += 1
        }
        return false
    }

    /// Whether two same-line tokens need a separating space. Rule of thumb:
    /// everything separates, except tightening around ( ) , ; . :: and
    /// function-call parentheses.
    private static func needsSpace(after prev: Token, before current: Token) -> Bool {
        let closing = [")", ",", ";", ".", "::"]
        if closing.contains(current.text) { return false }
        let opening = ["(", ".", "::"]
        if opening.contains(prev.text) { return false }
        if current.text == "(" {
            if prev.kind == .word {
                return parenSpaceKeywords.contains(prev.text.uppercased())
            }
            return prev.kind == .comment
        }
        return true
    }
}
