import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for EXPLAIN statement construction (ROADMAP M2 ⑧):
/// per-engine prefixes, and fail-closed nil for MongoDB (its explain is a
/// command document, covered by MongoExplainPlannerTests).
final class ExplainPlannerTests: XCTestCase {
    func testPostgreSQLAndMySQLUsePlainExplainPrefix() {
        XCTAssertEqual(
            ExplainPlanner.statement(engine: .postgresql, query: "SELECT 1"),
            "EXPLAIN SELECT 1")
        XCTAssertEqual(
            ExplainPlanner.statement(engine: .mysql, query: "select * from t"),
            "EXPLAIN select * from t")
    }

    func testSQLiteUsesExplainQueryPlanPrefix() {
        XCTAssertEqual(
            ExplainPlanner.statement(engine: .sqlite, query: "SELECT 1"),
            "EXPLAIN QUERY PLAN SELECT 1")
    }

    /// The query text crosses verbatim — no reformatting, no semicolon games.
    func testQueryTextIsAppendedVerbatim() {
        XCTAssertEqual(
            ExplainPlanner.statement(engine: .postgresql, query: "SELECT 1;"),
            "EXPLAIN SELECT 1;")
    }

    func testMongoDBHasNoExplainStatement() {
        XCTAssertNil(ExplainPlanner.statement(engine: .mongodb, query: "{ }"))
    }
}
