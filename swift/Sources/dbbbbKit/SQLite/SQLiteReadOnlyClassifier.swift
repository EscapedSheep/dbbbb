import Foundation
import dbbbbCore

/// Error surfaced by the SQLite adapter. `userMessage` is already redacted:
/// no file paths, no SQL beyond the classifier's own echo of a rejected token.
public struct SQLiteAdapterError: dbbbbError, Equatable {
    public let userMessage: String
    public init(_ userMessage: String) {
        self.userMessage = userMessage
    }
}

/// Conservative, fail-closed: WITH can prefix writes in SQLite and writable
/// PRAGMAs (e.g. writable_schema) mutate the database, so the starter check
/// alone is not enough and PRAGMA is never allowed through.
private let allowedReadOnlyStarters: Set<String> = ["EXPLAIN", "SELECT", "WITH"]

// END and REPLACE are deliberately absent: END legally closes a CASE
// expression and REPLACE is the replace() string function. Their statement
// forms (END [TRANSACTION], REPLACE INTO) are rejected because neither is an
// allowed starter, and an END that closes no CASE is rejected below.
private let forbiddenReadOnlyTokens: Set<String> = [
    "ALTER", "ANALYZE", "ATTACH", "BEGIN", "COMMIT", "CREATE", "DELETE",
    "DETACH", "DROP", "INSERT", "PRAGMA", "REINDEX", "RELEASE",
    "ROLLBACK", "SAVEPOINT", "TRANSACTION", "UPDATE", "VACUUM",
]

// Strips comments (-- and /* */) and quoted literals/identifiers, then
// enforces exactly one statement. Returns the statement's uppercase tokens.
// Anything ambiguous (unterminated quotes/comments) throws, so callers fail
// closed instead of guessing at intent.
func inspectSQLiteSQL(_ sql: String) throws -> [String] {
    let bytes = Array(sql.utf8)
    var visible: [UInt8] = []
    var index = 0

    func classificationError(_ start: Int) -> SQLiteAdapterError {
        SQLiteAdapterError("Read-only mode could not safely classify SQL near character \(start + 1).")
    }

    func skipQuoted(_ quote: UInt8) throws {
        let start = index
        index += 1
        while index < bytes.count {
            if bytes[index] == quote {
                if index + 1 < bytes.count, bytes[index + 1] == quote {
                    index += 2
                    continue
                }
                index += 1
                visible.append(0x20) // space
                return
            }
            index += 1
        }
        throw classificationError(start)
    }

    while index < bytes.count {
        let byte = bytes[index]

        if byte == 0x2D /* - */, index + 1 < bytes.count, bytes[index + 1] == 0x2D {
            var newline = index + 2
            while newline < bytes.count, bytes[newline] != 0x0A /* \n */ { newline += 1 }
            index = newline < bytes.count ? newline + 1 : bytes.count
            visible.append(0x20)
            continue
        }

        // SQLite block comments do not nest; treating nested
        // openers as fatal keeps the classifier fail-closed where the two
        // grammars disagree.
        if byte == 0x2F /* / */, index + 1 < bytes.count, bytes[index + 1] == 0x2A /* * */ {
            let start = index
            var depth = 1
            index += 2
            while index < bytes.count, depth > 0 {
                if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                    depth += 1
                    index += 2
                } else if bytes[index] == 0x2A, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            if depth != 0 { throw classificationError(start) }
            visible.append(0x20)
            continue
        }

        if byte == 0x27 /* ' */ || byte == 0x22 /* " */ || byte == 0x60 /* ` */ {
            try skipQuoted(byte)
            continue
        }

        // Bracket-quoted identifier: [...].
        if byte == 0x5B /* [ */ {
            let start = index
            var end = index + 1
            while end < bytes.count, bytes[end] != 0x5D /* ] */ { end += 1 }
            if end >= bytes.count { throw classificationError(start) }
            index = end + 1
            visible.append(0x20)
            continue
        }

        visible.append(byte)
        index += 1
    }

    let visibleText = String(decoding: visible, as: UTF8.self)
    let statements = visibleText
        .split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard statements.count == 1, let statement = statements.first else {
        throw SQLiteAdapterError("SQLite connections only allow one SQL statement at a time.")
    }

    return statement.uppercased().matches(of: /[A-Z_][A-Z0-9_]*/).map { String($0.output) }
}

/// Read-only sessions only run single read-only statements. The engine-level
/// read-only open is the second line of defense; this classifier is the first.
/// Table-valued pragma functions (`pragma_table_info(...)`, …) tokenize as a
/// single `PRAGMA_…` word, so they are rejected by prefix — same fail-closed
/// rule as the `PRAGMA` statement form.
func assertSQLiteReadOnlySQL(_ sql: String) throws {
    let tokens = try inspectSQLiteSQL(sql)
    guard let starter = tokens.first, allowedReadOnlyStarters.contains(starter) else {
        throw SQLiteAdapterError("Read-only connections only allow read-only SQL statements.")
    }
    if let forbidden = tokens.first(where: { forbiddenReadOnlyTokens.contains($0) || $0.hasPrefix("PRAGMA_") }) {
        throw SQLiteAdapterError("Read-only connections do not allow the SQL token \(forbidden).")
    }
    // END is legal only as the closing keyword of a CASE expression; an END
    // with no open CASE is the transaction statement (a COMMIT synonym) or
    // malformed input, so it stays rejected.
    var openCases = 0
    for token in tokens {
        switch token {
        case "CASE":
            openCases += 1
        case "END":
            guard openCases > 0 else {
                throw SQLiteAdapterError("Read-only connections do not allow the SQL token END.")
            }
            openCases -= 1
        default:
            break
        }
    }
}
