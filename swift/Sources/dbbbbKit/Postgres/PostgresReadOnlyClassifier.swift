import Foundation
import dbbbbCore

/// Thrown when SQL cannot be proven read-only. Classification is fail-closed:
/// anything the scanner cannot fully understand is rejected.
public struct PostgresReadOnlyViolation: dbbbbError, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var userMessage: String { reason }
}

/// Client-side guardrail that decides whether one SQL string is provably
/// read-only. The server-side `default_transaction_read_only` session setting
/// remains the second line of defense; this classifier exists to give precise
/// feedback before a statement is sent.
///
/// Ported from the Electron adapter (`src/main/adapters/postgres-adapter.ts`):
/// it strips `--` comments, nested `/* */` comments, dollar-quoted strings and
/// quoted literals before tokenizing. Crucially, backslashes are only escape
/// characters inside `E'...'` strings; in plain strings they are literal
/// (`standard_conforming_strings = on`).
public enum PostgresReadOnlyClassifier {
    public static let allowedStarters: Set<String> = [
        "EXPLAIN", "SELECT", "SHOW", "TABLE", "VALUES", "WITH",
    ]

    public static let forbiddenTokens: Set<String> = [
        "ALTER", "ANALYZE", "BEGIN", "CALL", "CHECKPOINT", "CLUSTER", "COMMENT",
        "COMMIT", "COPY", "CREATE", "DEALLOCATE", "DELETE", "DISCARD", "DO",
        "DROP", "EXECUTE", "GRANT", "INSERT", "INTO", "LISTEN", "LOAD", "LOCK",
        "MERGE", "MOVE", "NEXTVAL", "NOTIFY", "PG_ADVISORY_LOCK",
        "PG_ADVISORY_XACT_LOCK", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF",
        "PG_ROTATE_LOGFILE", "PG_TERMINATE_BACKEND", "PG_TRY_ADVISORY_LOCK",
        "PG_TRY_ADVISORY_XACT_LOCK", "PREPARE", "REASSIGN", "REFRESH", "REINDEX",
        "RELEASE", "RESET", "REVOKE", "ROLLBACK", "SAVEPOINT", "SET",
        "SET_CONFIG", "SETVAL", "START", "TRUNCATE", "UNLISTEN", "UPDATE",
        "VACUUM",
    ]

    /// Throws `PostgresReadOnlyViolation` unless `sql` is a single,
    /// provably read-only statement.
    public static func assertReadOnly(_ sql: String) throws {
        let tokens = try inspect(sql)
        guard let starter = tokens.first, allowedStarters.contains(starter) else {
            throw PostgresReadOnlyViolation(
                reason: "Read-only connections only allow read-only SQL statements.")
        }
        if let forbidden = tokens.first(where: forbiddenTokens.contains) {
            throw PostgresReadOnlyViolation(
                reason: "Read-only connections do not allow the SQL token \(forbidden).")
        }
    }

    /// Strips comments and string content, then returns the uppercase word
    /// tokens of the single remaining statement. Fails closed on anything
    /// unbalanced or on multiple statements.
    static func inspect(_ sql: String) throws -> [String] {
        let characters = Array(sql)
        var visible: [Character] = []
        var index = 0

        func startsWith(_ literal: String, at position: Int) -> Bool {
            let literalCharacters = Array(literal)
            guard position + literalCharacters.count <= characters.count else { return false }
            return Array(characters[position..<position + literalCharacters.count]) == literalCharacters
        }

        func classificationError(at start: Int) -> PostgresReadOnlyViolation {
            PostgresReadOnlyViolation(
                reason: "Read-only mode could not safely classify SQL near character \(start + 1).")
        }

        func skipQuoted(_ quote: Character, escapeBackslash: Bool = false) throws {
            let start = index
            index += 1
            while index < characters.count {
                let character = characters[index]
                if character == quote {
                    if index + 1 < characters.count && characters[index + 1] == quote {
                        index += 2
                        continue
                    }
                    index += 1
                    visible.append(" ")
                    return
                }
                // Only E'...' escape strings treat backslash as an escape; with
                // standard_conforming_strings=on a plain string keeps it literally.
                if escapeBackslash && character == "\\" && index + 1 < characters.count {
                    index += 2
                    continue
                }
                index += 1
            }
            throw classificationError(at: start)
        }

        func isIdentifierCharacter(_ character: Character) -> Bool {
            character == "$" || character == "_" || character.isLetter || character.isNumber
        }

        while index < characters.count {
            if startsWith("--", at: index) {
                var newline = index + 2
                while newline < characters.count && characters[newline] != "\n" { newline += 1 }
                index = newline < characters.count ? newline + 1 : characters.count
                visible.append(" ")
                continue
            }

            if startsWith("/*", at: index) {
                let start = index
                var depth = 1
                index += 2
                while index < characters.count && depth > 0 {
                    if startsWith("/*", at: index) {
                        depth += 1
                        index += 2
                    } else if startsWith("*/", at: index) {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                if depth != 0 { throw classificationError(at: start) }
                visible.append(" ")
                continue
            }

            let character = characters[index]

            if character == "'" {
                // E'...'/e'...' escape strings only when the E/e is a standalone prefix,
                // not the tail of an identifier such as `mode`.
                let previous = index > 0 ? characters[index - 1] : nil
                let beforePrevious = index > 1 ? characters[index - 2] : nil
                let escapeString = (previous == "E" || previous == "e")
                    && (beforePrevious == nil || !isIdentifierCharacter(beforePrevious!))
                try skipQuoted("'", escapeBackslash: escapeString)
                continue
            }

            if character == "\"" {
                try skipQuoted("\"")
                continue
            }

            if character == "$" {
                // Dollar-quoted string tag: `$` or `$tag$` (ASCII tag name).
                var tagEnd = index + 1
                if tagEnd < characters.count,
                   characters[tagEnd].isASCII,
                   characters[tagEnd].isLetter || characters[tagEnd] == "_" {
                    tagEnd += 1
                    while tagEnd < characters.count,
                          characters[tagEnd].isASCII,
                          characters[tagEnd].isLetter || characters[tagEnd].isNumber
                            || characters[tagEnd] == "_" {
                        tagEnd += 1
                    }
                }
                if tagEnd < characters.count && characters[tagEnd] == "$" {
                    let tag = String(characters[index...tagEnd])
                    let start = index
                    var search = tagEnd + 1
                    var found = -1
                    while search + tag.count <= characters.count {
                        if startsWith(tag, at: search) { found = search; break }
                        search += 1
                    }
                    if found == -1 { throw classificationError(at: start) }
                    index = found + tag.count
                    visible.append(" ")
                    continue
                }
            }

            visible.append(character)
            index += 1
        }

        let statements = String(visible)
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard statements.count == 1, let statement = statements.first else {
            throw PostgresReadOnlyViolation(
                reason: "Read-only connections only allow one SQL statement at a time.")
        }

        return wordTokens(of: statement.uppercased())
    }

    /// Matches `[A-Z_][A-Z0-9_$]*` over the (already uppercased) statement.
    private static func wordTokens(of statement: String) -> [String] {
        func isStart(_ scalar: Unicode.Scalar) -> Bool {
            (scalar >= "A" && scalar <= "Z") || scalar == "_"
        }
        func isContinuation(_ scalar: Unicode.Scalar) -> Bool {
            isStart(scalar) || (scalar >= "0" && scalar <= "9") || scalar == "$"
        }

        var tokens: [String] = []
        var current = ""
        for scalar in statement.unicodeScalars {
            if !current.isEmpty {
                if isContinuation(scalar) {
                    current.unicodeScalars.append(scalar)
                } else {
                    tokens.append(current)
                    current = ""
                    if isStart(scalar) { current.unicodeScalars.append(scalar) }
                }
            } else if isStart(scalar) {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
