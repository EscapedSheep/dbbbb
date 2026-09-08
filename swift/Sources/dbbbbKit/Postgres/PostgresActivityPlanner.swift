import Foundation
import dbbbbCore

/// Pure query + row parsing for the PostgreSQL activity viewer (ROADMAP M2 ⑨).
enum PostgresActivityPlanner {
    /// One row per backend except our own (killing the connection that serves
    /// the list would be self-sabotage; our own in-flight query is cancelled
    /// through the normal cancel path anyway). The pid and the age cross as
    /// text so the byte-wise decoders stay shared with the other catalog
    /// queries; the statement is excerpted server-side. Idle backends
    /// (`query_start` NULL) sort last and report no age.
    static let listActivitySQL = """
        SELECT pid::text,
               usename,
               datname,
               state,
               EXTRACT(EPOCH FROM (now() - query_start))::text,
               left(query, \(ServerActivity.statementLimit))
        FROM pg_catalog.pg_stat_activity
        WHERE pid <> pg_catalog.pg_backend_pid()
        ORDER BY query_start NULLS LAST
        """

    /// Maps one decoded row; nil when the pid cell is missing or empty (the
    /// row is then unusable as a kill target and is dropped).
    static func activity(
        pid: String?,
        user: String?,
        database: String?,
        state: String?,
        ageSeconds: Double?,
        statement: String?
    ) -> ServerActivity? {
        guard let pid, !pid.isEmpty else { return nil }
        return ServerActivity(
            id: pid,
            user: user,
            database: database,
            statement: statement,
            age: ageSeconds.map { .milliseconds(Int64(($0 * 1000).rounded())) },
            state: state)
    }

    /// Parses the `EXTRACT(EPOCH …)::text` age; missing, unparseable,
    /// negative, or absurd values mean "unknown", never zero (and the Double
    /// → Int64 conversion must never overflow).
    static func ageSeconds(_ text: String?) -> Double? {
        guard let text, let seconds = Double(text.trimmingCharacters(in: .whitespaces)),
              seconds.isFinite, seconds >= 0, seconds < 9e15 else { return nil }
        return seconds
    }
}
