import Foundation
import dbbbbCore

/// A planned MySQL preview: the statement text plus the values to bind (LIKE
/// pattern and/or equality values). Identifiers are backtick-quoted with the
/// throwing `MySQLChangePlanner` rule (empty/NUL rejected); values are never
/// interpolated — the adapter binds them into session variables through the
/// binary protocol (see `MySQLAdapter.previewObject`), so the result rows
/// themselves stay on the text protocol and keep the exact display semantics
/// of unfiltered previews.
public struct MySQLPreviewPlan: Sendable, Equatable {
    public let text: String
    /// Client-escaped `%…%` LIKE pattern the adapter binds to
    /// `@dbbbb_preview_filter`; nil when unfiltered.
    public let filterPattern: String?
    /// The non-NULL equality values in `@dbbbb_preview_eq_N` order (NULL
    /// equalities are rendered as `IS NULL` and bind nothing). The adapter
    /// converts each via `MySQLChangeMapper.bind`.
    public let equalityValues: [DisplayValue]
    /// Prepared statement binding every equality value into its session
    /// variable (`SET @dbbbb_preview_eq_0 = ?, …`); nil when there are no
    /// non-NULL equalities. Contains placeholders only — no user input
    /// reaches the text.
    public let bindEqualitiesStatement: String?
    /// Page size the caller should pass as `ExecuteOptions.maxRows`; the SQL
    /// fetches `limit + 1` so `ResultMeta.truncated` signals a next page.
    public let limit: Int
    public let offset: Int

    public init(
        text: String,
        filterPattern: String?,
        equalityValues: [DisplayValue],
        bindEqualitiesStatement: String?,
        limit: Int,
        offset: Int
    ) {
        self.text = text
        self.filterPattern = filterPattern
        self.equalityValues = equalityValues
        self.bindEqualitiesStatement = bindEqualitiesStatement
        self.limit = limit
        self.offset = offset
    }
}

/// Pure planner for paged/sorted/filtered MySQL previews. Mirrors
/// `PostgresPreviewPlanner`: `CAST(col AS CHAR) LIKE` for the grid filter
/// (LIKE's default backslash escape is independent of NO_BACKSLASH_ESCAPES,
/// which only affects string literal parsing — and no literal is involved
/// anyway), the null-safe `<=>` against per-equality session variables for
/// exact matches, `ORDER BY` on the quoted sort column, `LIMIT l + 1 OFFSET o`.
public enum MySQLPreviewPlanner {
    /// Session variable carrying the bound filter pattern; fixed name is safe
    /// because the leased connection runs exactly this one preview at a time.
    public static let filterVariable = "@dbbbb_preview_filter"

    /// Prepared statement that binds the filter pattern into the session
    /// variable; runs on the same leased connection right before the preview.
    public static let bindFilterStatement = "SET @dbbbb_preview_filter = ?"

    /// Session variable for the Nth (0-based) non-NULL equality value.
    public static func equalityVariable(_ index: Int) -> String {
        "@dbbbb_preview_eq_\(index)"
    }

    public static func plan(
        database: String,
        table: String,
        request: PreviewRequest
    ) throws -> MySQLPreviewPlan {
        let limit = request.normalizedLimit
        let offset = request.normalizedOffset
        let qualified = try "\(MySQLChangePlanner.quoteIdentifier(database))"
            + ".\(MySQLChangePlanner.quoteIdentifier(table))"

        var clauses = ["SELECT *", "FROM \(qualified)"]
        var conditions: [String] = []
        var filterPattern: String?
        var equalityValues: [DisplayValue] = []
        if let filter = request.filter {
            conditions.append(
                "CAST(\(try MySQLChangePlanner.quoteIdentifier(filter.column)) AS CHAR) LIKE \(filterVariable)")
            filterPattern = PreviewRequest.likePattern(containing: filter.contains)
        }
        for equality in request.equalities {
            let quoted = try MySQLChangePlanner.quoteIdentifier(equality.column)
            if equality.value == .null {
                conditions.append("\(quoted) IS NULL")
            } else {
                conditions.append("\(quoted) <=> \(equalityVariable(equalityValues.count))")
                equalityValues.append(equality.value)
            }
        }
        if !conditions.isEmpty {
            clauses.append("WHERE " + conditions.joined(separator: "\n  AND "))
        }
        if let sort = request.sort {
            clauses.append(
                "ORDER BY \(try MySQLChangePlanner.quoteIdentifier(sort.column)) \(sort.ascending ? "ASC" : "DESC")")
        }
        clauses.append("LIMIT \(limit + 1) OFFSET \(offset)")

        let bindEqualities = equalityValues.isEmpty ? nil
            : "SET " + equalityValues.indices.map { "\(equalityVariable($0)) = ?" }.joined(separator: ", ")

        return MySQLPreviewPlan(
            text: clauses.joined(separator: "\n"),
            filterPattern: filterPattern,
            equalityValues: equalityValues,
            bindEqualitiesStatement: bindEqualities,
            limit: limit,
            offset: offset)
    }
}
