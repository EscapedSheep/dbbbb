import Foundation
import dbbbbCore

/// Pure planner for SQLite CSV imports. Batches insert row-by-row through one
/// prepared single-tuple statement, so the only bound is the driver's 500-row
/// default (each batch is one write transaction).
enum SQLiteImportPlanner {
    static let batchSize = 500

    /// `INSERT INTO "table" ("a", "b") VALUES (?, ?)` — values only ever cross
    /// as bind parameters, never in the text. SQLite's column affinity coerces
    /// the bound text into the column's storage class on INSERT.
    static func insertStatement(table: String, columns: [String]) throws -> String {
        guard !columns.isEmpty else {
            throw SQLiteAdapterError("SQLite import requires at least one insertable column.")
        }
        let columnList = try columns.map { try quoteIdentifier($0) }.joined(separator: ", ")
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        return "INSERT INTO \(try quoteIdentifier(table)) (\(columnList)) VALUES (\(placeholders))"
    }

    static func quoteIdentifier(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\0") else {
            throw SQLiteAdapterError("SQLite identifiers must be non-empty strings without null bytes.")
        }
        return "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
