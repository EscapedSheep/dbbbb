import Foundation
import dbbbbCore

/// Pure EXPLAIN statement construction (ROADMAP M2 ⑧). The read-only
/// classifiers of all three SQL engines already allow the `EXPLAIN` starter
/// (PostgreSQL additionally rejects the `ANALYZE` token), so the prefixed
/// statement flows through the normal execution path — bounded result,
/// timeout, cancellation, and redacted errors all reuse it. MongoDB has no
/// EXPLAIN prefix: its explain is a command document, built by
/// `MongoExplainPlanner`.
public enum ExplainPlanner {
    /// `EXPLAIN <query>` (SQLite: `EXPLAIN QUERY PLAN <query>`); nil for
    /// MongoDB, which never reaches this path.
    public static func statement(engine: DatabaseEngine, query: String) -> String? {
        switch engine {
        case .postgresql, .mysql:
            return "EXPLAIN " + query
        case .sqlite:
            return "EXPLAIN QUERY PLAN " + query
        case .mongodb:
            return nil
        }
    }
}
