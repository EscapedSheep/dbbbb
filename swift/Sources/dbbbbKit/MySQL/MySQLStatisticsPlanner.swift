import Foundation
import dbbbbCore

/// Pure query + row parsing for MySQL table statistics (ROADMAP M2 ⑩).
enum MySQLStatisticsPlanner {
    /// `TABLE_ROWS` is InnoDB's estimate (exact for MyISAM). The numeric
    /// columns cross as `CAST(... AS CHAR)` so the binary protocol hands
    /// them over as text and NULLs (views, missing stats) survive as NULL;
    /// the schema/table names cross as binds, never interpolated, so
    /// server-wide (database-less) connections stay correctly qualified.
    static let statisticsSQL = """
        SELECT CAST(TABLE_ROWS AS CHAR) AS TABLE_ROWS,
               CAST(DATA_LENGTH AS CHAR) AS DATA_LENGTH,
               CAST(INDEX_LENGTH AS CHAR) AS INDEX_LENGTH
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ?
          AND TABLE_NAME = ?
        """

    static func statistics(rows: String?, dataBytes: String?, indexBytes: String?) -> TableStatistics {
        TableStatistics(
            estimatedRows: int64(rows),
            totalBytes: int64(dataBytes),
            indexBytes: int64(indexBytes))
    }

    static func int64(_ text: String?) -> Int64? {
        guard let text,
              let value = Int64(text.trimmingCharacters(in: .whitespaces)),
              value >= 0
        else { return nil }
        return value
    }
}
