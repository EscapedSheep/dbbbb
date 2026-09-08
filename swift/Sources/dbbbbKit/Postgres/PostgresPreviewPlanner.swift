import Foundation
import dbbbbCore

/// A planned PostgreSQL preview: the statement text plus the values to bind
/// (LIKE pattern and/or equality values, in placeholder order). Identifiers
/// are quoted with the exact rule `PostgresChangePlanner.quoteIdentifier`
/// uses; values are never interpolated — they cross as binds `$1…`.
public struct PostgresPreviewPlan: Sendable, Equatable {
    public let sql: String
    /// Client-escaped `%…%` LIKE pattern; bound first when a grid filter is
    /// active, nil when unfiltered.
    public let filterPattern: String?
    /// The non-NULL equality values in placeholder order (NULL equalities are
    /// rendered as `IS NULL` and bind nothing). The adapter converts each via
    /// `PostgresChangeMapper.bindText` and binds it as unknown-typed text, so
    /// the server infers the parameter type from the compared column.
    public let equalityValues: [DisplayValue]
    /// Page size the caller should pass as `ExecuteOptions.maxRows`; the SQL
    /// fetches `limit + 1` so `ResultMeta.truncated` signals a next page.
    public let limit: Int
    public let offset: Int

    public init(sql: String, filterPattern: String?, equalityValues: [DisplayValue], limit: Int, offset: Int) {
        self.sql = sql
        self.filterPattern = filterPattern
        self.equalityValues = equalityValues
        self.limit = limit
        self.offset = offset
    }
}

/// Pure planner for paged/sorted/filtered PostgreSQL previews. The qualified
/// table name is already safe (adapter-issued handle, quoted here), so the
/// planner only appends clauses: a bound `::text LIKE` filter, bound
/// null-safe `IS NOT DISTINCT FROM` equality predicates (the same operator
/// the change planner's optimistic lock uses), an `ORDER BY` on the quoted
/// sort column, and `LIMIT l + 1 OFFSET o` (the extra row is the
/// has-next-page probe).
public enum PostgresPreviewPlanner {
    public static func plan(
        schema: String,
        table: String,
        request: PreviewRequest
    ) throws -> PostgresPreviewPlan {
        let limit = request.normalizedLimit
        let offset = request.normalizedOffset
        let qualified = try "\(PostgresChangePlanner.quoteIdentifier(schema))"
            + ".\(PostgresChangePlanner.quoteIdentifier(table))"

        var clauses = ["SELECT *", "FROM \(qualified)"]
        var conditions: [String] = []
        var filterPattern: String?
        var equalityValues: [DisplayValue] = []
        if let filter = request.filter {
            conditions.append(
                "\(try PostgresChangePlanner.quoteIdentifier(filter.column))::text LIKE $1 ESCAPE '\\'")
            filterPattern = PreviewRequest.likePattern(containing: filter.contains)
        }
        for equality in request.equalities {
            let quoted = try PostgresChangePlanner.quoteIdentifier(equality.column)
            if equality.value == .null {
                conditions.append("\(quoted) IS NULL")
            } else {
                equalityValues.append(equality.value)
                let placeholder = equalityValues.count + (filterPattern == nil ? 0 : 1)
                conditions.append("\(quoted) IS NOT DISTINCT FROM $\(placeholder)")
            }
        }
        if !conditions.isEmpty {
            clauses.append("WHERE " + conditions.joined(separator: "\n  AND "))
        }
        if let sort = request.sort {
            clauses.append(
                "ORDER BY \(try PostgresChangePlanner.quoteIdentifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")")
        }
        clauses.append("LIMIT \(limit + 1) OFFSET \(offset);")

        return PostgresPreviewPlan(
            sql: clauses.joined(separator: "\n"),
            filterPattern: filterPattern,
            equalityValues: equalityValues,
            limit: limit,
            offset: offset)
    }
}
