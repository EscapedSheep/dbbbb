import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

/// The MongoDB explain command document shape (ROADMAP M2 ⑧): the parsed
/// find/aggregate command is wrapped verbatim as `{explain: <cmd>,
/// verbosity: "queryPlanner"}`.
struct MongoExplainPlannerTests {
    @Test func wrapsAFindCommand() {
        let inner: [(key: String, value: BSONValue)] = [
            ("find", .string("events")),
            ("filter", .document([("kind", .string("click"))])),
            ("limit", .int64(101)),
            ("maxTimeMS", .int64(30_000)),
        ]
        let command = MongoExplainPlanner.explainCommandPairs(inner: inner)
        #expect(command.map(\.key) == ["explain", "verbosity"])
        #expect(command[0].value == .document(inner))
        #expect(command[1].value == .string("queryPlanner"))
    }

    @Test func wrapsAnAggregateCommand() {
        let inner: [(key: String, value: BSONValue)] = [
            ("aggregate", .string("events")),
            ("pipeline", .array([.document([("$match", .document([]))])])),
            ("cursor", .document([])),
            ("maxTimeMS", .int64(30_000)),
        ]
        let command = MongoExplainPlanner.explainCommandPairs(inner: inner)
        #expect(command.map(\.key) == ["explain", "verbosity"])
        #expect(command[0].value == .document(inner))
        #expect(command[1].value == .string("queryPlanner"))
    }

    /// The inner command keeps its own maxTimeMS — planning work stays
    /// bounded by the same budget the run would have had.
    @Test func innerMaxTimeMSSurvivesTheWrap() {
        let inner: [(key: String, value: BSONValue)] = [
            ("find", .string("c")),
            ("maxTimeMS", .int64(1234)),
        ]
        guard case .document(let wrapped) = MongoExplainPlanner.explainCommandPairs(inner: inner)[0].value
        else {
            Issue.record("explain value must be the inner command document")
            return
        }
        #expect(wrapped.last?.key == "maxTimeMS")
        #expect(wrapped.last?.value == .int64(1234))
    }
}
