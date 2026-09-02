import Foundation

/// Pure read-only SQL classifier, a faithful port of the Electron adapter's
/// `inspectSql`/`assertReadOnlySql` (mysql-adapter.ts). Fail-closed: anything
/// it cannot prove inert is rejected.
///
/// MySQL lexical rules honored here:
/// - Backtick identifiers have no backslash escapes; a doubled backtick escapes.
/// - String literals (`'`, `"`) treat `\` as an escape (NO_BACKSLASH_ESCAPES off, the default).
/// - `#` starts a comment to end-of-line.
/// - `--` starts a comment only when whitespace (or EOF) follows; `1--1` is a valid expression.
/// - `/* ... */` comments are inert, but versioned `/*! ... */` comments EXECUTE on
///   matching server versions, so they are rejected outright.
enum MySQLReadOnlyClassifier {
    static let allowedStarters: Set<String> = ["DESCRIBE", "EXPLAIN", "SELECT", "SHOW", "WITH"]

    static let forbiddenTokens: Set<String> = [
        "ALTER", "ANALYZE", "BEGIN", "CALL", "CHANGE", "CHECK", "COMMIT", "CREATE",
        "DEALLOCATE", "DELETE", "DO", "DROP", "DUMPFILE", "EXECUTE", "FLUSH",
        "GET_LOCK", "GRANT", "HANDLER", "INSERT", "INSTALL", "INTO", "IS_FREE_LOCK",
        "IS_USED_LOCK", "KILL", "LOAD", "LOCK", "OPTIMIZE", "OUTFILE", "PREPARE",
        "PURGE", "RELEASE", "RELEASE_LOCK", "RENAME", "REPAIR", "REPLACE", "RESET",
        "REVOKE", "ROLLBACK", "SAVEPOINT", "SET", "SHUTDOWN", "START", "STOP",
        "TRUNCATE", "UNINSTALL", "UNLOCK", "UPDATE", "USE", "XA",
    ]

    static func assertReadOnly(_ sql: String) throws {
        let tokens = try visibleTokens(sql)
        guard let first = tokens.first, allowedStarters.contains(first) else {
            throw MySQLAdapterError.statementNotReadOnly
        }
        for token in tokens where forbiddenTokens.contains(token) {
            throw MySQLAdapterError.forbiddenToken(token)
        }
    }

    /// Strips comments and literals, requires exactly one statement, and returns the
    /// statement's uppercase word tokens (`[A-Z_][A-Z0-9_$]*`).
    static func visibleTokens(_ sql: String) throws -> [String] {
        let characters = Array(sql)
        var visible = ""
        var index = 0

        func skipQuoted(_ quote: Character) throws {
            let start = index
            index += 1
            while index < characters.count {
                let character = characters[index]
                if character == quote {
                    // A doubled quote is an escaped quote in strings and identifiers alike.
                    if index + 1 < characters.count, characters[index + 1] == quote {
                        index += 2
                        continue
                    }
                    index += 1
                    visible.append(" ")
                    return
                }
                // Backslash escapes the next character inside string literals,
                // but never inside backtick identifiers.
                if quote != "`", character == "\\", index + 1 < characters.count {
                    index += 2
                    continue
                }
                index += 1
            }
            throw MySQLAdapterError.unclassifiableSQL(position: start + 1)
        }

        while index < characters.count {
            let character = characters[index]

            if character == "#" {
                index = endOfLine(after: index + 1, in: characters)
                visible.append(" ")
                continue
            }

            if character == "-", index + 1 < characters.count, characters[index + 1] == "-" {
                // `--` is a comment only when whitespace (or the end of the statement)
                // follows; `1--1` is a valid expression and must stay visible.
                if index + 2 >= characters.count || characters[index + 2].isWhitespace {
                    index = endOfLine(after: index + 2, in: characters)
                    visible.append(" ")
                    continue
                }
            }

            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                let start = index
                // Versioned comments (`/*! ... */`) execute on matching server versions,
                // so the classifier cannot treat them as inert; fail closed instead.
                if index + 2 < characters.count, characters[index + 2] == "!" {
                    throw MySQLAdapterError.unclassifiableSQL(position: start + 1)
                }
                index += 2
                var closed = false
                while index + 1 < characters.count {
                    if characters[index] == "*", characters[index + 1] == "/" {
                        closed = true
                        break
                    }
                    index += 1
                }
                guard closed else {
                    throw MySQLAdapterError.unclassifiableSQL(position: start + 1)
                }
                index += 2
                visible.append(" ")
                continue
            }

            if character == "'" || character == "\"" || character == "`" {
                try skipQuoted(character)
                continue
            }

            visible.append(character)
            index += 1
        }

        let statements = visible
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard statements.count == 1, let statement = statements.first else {
            throw MySQLAdapterError.multipleStatements
        }
        return wordTokens(of: statement.uppercased())
    }

    private static func endOfLine(after index: Int, in characters: [Character]) -> Int {
        var cursor = index
        while cursor < characters.count, characters[cursor] != "\n" {
            cursor += 1
        }
        return cursor < characters.count ? cursor + 1 : characters.count
    }

    /// Extracts `[A-Z_][A-Z0-9_$]*` tokens from an already-uppercased statement.
    private static func wordTokens(of statement: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func isUpper(_ character: Character) -> Bool { character >= "A" && character <= "Z" }
        func isDigit(_ character: Character) -> Bool { character >= "0" && character <= "9" }
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }

        for character in statement {
            if current.isEmpty {
                if isUpper(character) || character == "_" {
                    current.append(character)
                }
            } else if isUpper(character) || isDigit(character) || character == "_" || character == "$" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
