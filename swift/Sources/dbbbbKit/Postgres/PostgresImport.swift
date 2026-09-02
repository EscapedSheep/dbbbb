import Foundation
import dbbbbCore

/// Pure planner for PostgreSQL CSV imports: parameterized multi-row INSERT
/// text and the parameter-limit-aware batch size, ported from the Electron
/// adapter's `postgresInsertQuery`/`postgresImportBatchSize`.
enum PostgresImportPlanner {
    static let maxParameters = 65_535
    static let defaultBatchSize = 500

    /// The largest batch whose placeholders fit the protocol's parameter
    /// limit, capped at the shared 500-row default.
    static func batchSize(columnCount: Int) throws -> Int {
        guard columnCount >= 1 else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL import requires at least one insertable column.")
        }
        let parameterBound = maxParameters / columnCount
        guard parameterBound >= 1 else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL import has too many columns for a parameterized insert.")
        }
        return min(defaultBatchSize, parameterBound)
    }

    /// `INSERT INTO "schema"."table" ("a", "b") VALUES ($1, $2), …` — values
    /// only ever cross as bind parameters, never in the text.
    static func insertStatement(
        schema: String,
        table: String,
        columns: [String],
        rowCount: Int
    ) throws -> String {
        guard rowCount >= 1 else {
            throw PostgresChangePlanError(reason: "PostgreSQL import received an empty batch.")
        }
        guard !columns.isEmpty, columns.count * rowCount <= maxParameters else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL import batch exceeds the parameter limit.")
        }
        let qualifiedTable = try "\(PostgresChangePlanner.quoteIdentifier(schema))."
            + "\(PostgresChangePlanner.quoteIdentifier(table))"
        let columnList = try columns
            .map { try PostgresChangePlanner.quoteIdentifier($0) }
            .joined(separator: ", ")
        let tuples = (0..<rowCount).map { row in
            let start = row * columns.count + 1
            let placeholders = (0..<columns.count)
                .map { "$\($0 + start)" }
                .joined(separator: ", ")
            return "(\(placeholders))"
        }
        return """
            INSERT INTO \(qualifiedTable)
            (\(columnList))
            VALUES \(tuples.joined(separator: ",\n       "));
            """
    }
}

