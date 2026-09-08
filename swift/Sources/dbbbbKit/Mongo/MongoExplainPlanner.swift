import Foundation
import dbbbbCore

/// Pure planner for the MongoDB EXPLAIN viewer (ROADMAP M2 ⑧): wraps an
/// already-built find/aggregate command as
/// `{explain: <cmd>, verbosity: "queryPlanner"}`. queryPlanner verbosity
/// never executes the command, so explaining stays a read even for
/// aggregation pipelines (write stages were already rejected at parse time).
enum MongoExplainPlanner {
    static let verbosity = "queryPlanner"

    /// The explain document around one parsed find/aggregate command; the
    /// inner pairs keep their `maxTimeMS`, which bounds any planning work
    /// the server does for the explained command.
    static func explainCommandPairs(
        inner: [(key: String, value: BSONValue)]
    ) -> [(key: String, value: BSONValue)] {
        [
            ("explain", .document(inner)),
            ("verbosity", .string(verbosity)),
        ]
    }
}
