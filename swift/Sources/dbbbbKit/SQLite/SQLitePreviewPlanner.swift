import Foundation
import GRDB
import dbbbbCore

/// A planned SQLite preview: the statement text plus the values to bind
/// (LIKE pattern and/or equality values, in placeholder order). Identifiers
/// are double-quoted with the adapter's rule; values are never interpolated —
/// they cross as the statement's bound arguments.
public struct SQLitePreviewPlan: Sendable, Equatable {
    public let sql: String
    /// Client-escaped `%…%` LIKE pattern for the filter's `?` placeholder;
    /// nil when unfiltered.
    public let filterPattern: String?
    /// The non-NULL equality values in placeholder order (NULL equalities are
    /// rendered as `IS NULL` and bind nothing), already converted through
    /// `SQLiteChangeMapper.bind` (integral numbers bind as INTEGER so `=`
    /// matches the column's stored storage class).
    public let equalityBinds: [DatabaseValue]
    /// Page size the caller should pass as `ExecuteOptions.maxRows`; the SQL
    /// fetches `limit + 1` so `ResultMeta.truncated` signals a next page.
    public let limit: Int
    public let offset: Int

    public init(sql: String, filterPattern: String?, equalityBinds: [DatabaseValue], limit: Int, offset: Int) {
        self.sql = sql
        self.filterPattern = filterPattern
        self.equalityBinds = equalityBinds
        self.limit = limit
        self.offset = offset
    }
}

/// Pure planner for paged/sorted/filtered SQLite previews. Mirrors
/// `PostgresPreviewPlanner`: `CAST(col AS TEXT) LIKE ? ESCAPE '\'` (SQLite's
/// LIKE has no default escape character, so the clause is mandatory), `= ?`
/// for exact matches — the column's affinity converts the bound value, so
/// INTEGER/REAL/TEXT columns all match their displayed rendering; NULL
/// matches use `IS NULL` —, an `ORDER BY` on the quoted sort column, and
/// `LIMIT l + 1 OFFSET o`.
public enum SQLitePreviewPlanner {
    public static func plan(table: String, request: PreviewRequest) throws -> SQLitePreviewPlan {
        let limit = request.normalizedLimit
        let offset = request.normalizedOffset

        var clauses = try ["SELECT *", "FROM \(quoted(table))"]
        var conditions: [String] = []
        var filterPattern: String?
        var equalityBinds: [DatabaseValue] = []
        if let filter = request.filter {
            conditions.append("CAST(\(try quoted(filter.column)) AS TEXT) LIKE ? ESCAPE '\\'")
            filterPattern = PreviewRequest.likePattern(containing: filter.contains)
        }
        for equality in request.equalities {
            let quoted = try quoted(equality.column)
            if equality.value == .null {
                conditions.append("\(quoted) IS NULL")
            } else {
                // Column affinity applies to `=`, so no declared type is
                // needed for the bind conversion (columnType: nil).
                equalityBinds.append(try SQLiteChangeMapper.bind(
                    for: equality.value, columnType: nil, label: equality.column))
                conditions.append("\(quoted) = ?")
            }
        }
        if !conditions.isEmpty {
            clauses.append("WHERE " + conditions.joined(separator: "\n  AND "))
        }
        if let sort = request.sort {
            clauses.append("ORDER BY \(try quoted(sort.column)) \(sort.ascending ? "ASC" : "DESC")")
        }
        clauses.append("LIMIT \(limit + 1) OFFSET \(offset)")

        return SQLitePreviewPlan(
            sql: clauses.joined(separator: "\n"),
            filterPattern: filterPattern,
            equalityBinds: equalityBinds,
            limit: limit,
            offset: offset)
    }

    /// `SQLiteAdapter.quoteIdentifier` plus the fail-closed validation the
    /// other engines' planners do (empty/NUL names cannot be quoted safely).
    private static func quoted(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\0") else {
            throw SQLiteAdapterError("SQLite previews require a valid column or table name.")
        }
        return SQLiteAdapter.quoteIdentifier(name)
    }
}
