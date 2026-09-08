import Foundation
import dbbbbCore

/// Pure query + row parsing for PostgreSQL table statistics (ROADMAP M2 ⑩).
enum PostgresStatisticsPlanner {
    /// `reltuples` is the planner's row estimate (-1 when the table was
    /// never analyzed/vacuumed); the sizes are exact bytes. The schema and
    /// table names cross as binds; the relkind set is fixed at plan time.
    static let statisticsSQL = """
        SELECT c.reltuples::bigint,
               pg_catalog.pg_total_relation_size(c.oid),
               pg_catalog.pg_indexes_size(c.oid)
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = $1
          AND c.relname = $2
          AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
        """

    /// -1 reltuples means "never analyzed": the estimate is unknown, not
    /// zero. NULL cells (defensive; the query never produces them) map to nil.
    static func statistics(reltuples: Int64?, totalBytes: Int64?, indexBytes: Int64?) -> TableStatistics {
        TableStatistics(
            estimatedRows: reltuples.flatMap { $0 >= 0 ? $0 : nil },
            totalBytes: totalBytes,
            indexBytes: indexBytes)
    }
}
