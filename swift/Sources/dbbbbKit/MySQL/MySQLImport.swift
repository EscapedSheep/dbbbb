import Foundation
import dbbbbCore

/// Pure planner for MySQL CSV imports: parameterized multi-row INSERT text
/// and the parameter-limit-aware batch size (same 65 535-placeholder protocol
/// limit and 500-row default as the PostgreSQL planner).
enum MySQLImportPlanner {
    static let maxParameters = 65_535
    static let defaultBatchSize = 500

    /// The largest batch whose placeholders fit the prepared-statement
    /// parameter limit, capped at the shared 500-row default.
    static func batchSize(columnCount: Int) throws -> Int {
        guard columnCount >= 1 else {
            throw MySQLAdapterError.failure(
                "MySQL import requires at least one insertable column.")
        }
        let parameterBound = maxParameters / columnCount
        guard parameterBound >= 1 else {
            throw MySQLAdapterError.failure(
                "MySQL import has too many columns for a parameterized insert.")
        }
        return min(defaultBatchSize, parameterBound)
    }

    /// `INSERT INTO `db`.`table` (`a`, `b`) VALUES (?, ?), …` — values only
    /// ever cross as bind parameters, never in the text.
    static func insertStatement(
        database: String,
        table: String,
        columns: [String],
        rowCount: Int
    ) throws -> String {
        guard rowCount >= 1 else {
            throw MySQLAdapterError.failure("MySQL import received an empty batch.")
        }
        guard !columns.isEmpty, columns.count * rowCount <= maxParameters else {
            throw MySQLAdapterError.failure(
                "MySQL import batch exceeds the parameter limit.")
        }
        let qualifiedTable = MySQLAdapter.quoteIdentifier(database)
            + "." + MySQLAdapter.quoteIdentifier(table)
        let columnList = columns.map(MySQLAdapter.quoteIdentifier).joined(separator: ", ")
        let tuple = "(" + columns.map { _ in "?" }.joined(separator: ", ") + ")"
        let tuples = (0..<rowCount).map { _ in tuple }.joined(separator: ",\n       ")
        return """
            INSERT INTO \(qualifiedTable)
            (\(columnList))
            VALUES \(tuples)
            """
    }
}
