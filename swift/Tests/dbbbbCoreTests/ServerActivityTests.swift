import Foundation
import Testing
@testable import dbbbbCore

/// The ServerActivity contract (ROADMAP M2 ⑨): everything optional except the
/// kill-handle id, statements excerpted to the shared limit.
struct ServerActivityTests {
    @Test func onlyIDIsRequired() {
        let activity = ServerActivity(id: "42")
        #expect(activity.id == "42")
        #expect(activity.user == nil)
        #expect(activity.database == nil)
        #expect(activity.statement == nil)
        #expect(activity.age == nil)
        #expect(activity.state == nil)
    }

    @Test func shortStatementsPassThrough() {
        #expect(ServerActivity.truncatedStatement("select 1") == "select 1")
        let exact = String(repeating: "x", count: ServerActivity.statementLimit)
        #expect(ServerActivity.truncatedStatement(exact) == exact)
    }

    @Test func longStatementsTruncateWithMarker() {
        let long = String(repeating: "x", count: ServerActivity.statementLimit + 50)
        let truncated = ServerActivity.truncatedStatement(long)
        #expect(truncated.count == ServerActivity.statementLimit + 1)
        #expect(truncated.hasSuffix("…"))
        #expect(truncated.hasPrefix(String(repeating: "x", count: 10)))
    }

    @Test func customLimitIsRespected() {
        #expect(ServerActivity.truncatedStatement("select 1", limit: 6) == "select…")
    }
}
