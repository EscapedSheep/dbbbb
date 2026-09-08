import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the MySQL activity commands (ROADMAP M2 ⑨): the
/// process-list query, the kill statement shape, and row parsing (NULL
/// cells, numeric text, statement excerpt cap).
final class MySQLActivityPlannerTests: XCTestCase {
    func testListActivityIsFullProcesslist() {
        XCTAssertEqual(MySQLActivityPlanner.listActivitySQL, "SHOW FULL PROCESSLIST")
    }

    /// The kill is `KILL` (full connection kill), not `KILL QUERY` — a
    /// process-list entry is a session.
    func testKillStatementShape() {
        XCTAssertEqual(MySQLActivityPlanner.killStatement(threadID: 42), "KILL 42")
        XCTAssertFalse(MySQLActivityPlanner.killStatement(threadID: 42).contains("QUERY"))
    }

    func testFullRowMaps() {
        let activity = MySQLActivityPlanner.activity(
            id: 58, user: "nightly", database: "shop",
            command: "Query", state: "Updating", timeSeconds: 95,
            info: "UPDATE products SET price = price * 1.05")
        XCTAssertEqual(activity?.id, "58")
        XCTAssertEqual(activity?.user, "nightly")
        XCTAssertEqual(activity?.database, "shop")
        XCTAssertEqual(activity?.statement, "UPDATE products SET price = price * 1.05")
        XCTAssertEqual(activity?.age, .seconds(95))
        // Command wins over State as the displayed state.
        XCTAssertEqual(activity?.state, "Query")
    }

    /// Missing Id → no kill handle → the row is dropped.
    func testMissingIDDropsTheRow() {
        XCTAssertNil(MySQLActivityPlanner.activity(
            id: nil, user: "u", database: "d", command: "Query", state: nil,
            timeSeconds: 1, info: "select 1"))
    }

    /// Sleeping threads: NULL db/Info/Time survive as nil; State is the
    /// fallback when Command is missing.
    func testNullCellsMapToNil() {
        let activity = MySQLActivityPlanner.activity(
            id: 61, user: "app", database: nil, command: nil,
            state: "statistics", timeSeconds: nil, info: nil)
        XCTAssertEqual(activity?.id, "61")
        XCTAssertNil(activity?.database)
        XCTAssertNil(activity?.statement)
        XCTAssertNil(activity?.age)
        XCTAssertEqual(activity?.state, "statistics")
    }

    /// FULL PROCESSLIST hands over the whole statement; the excerpt cap is
    /// applied client-side.
    func testInfoIsTruncated() {
        let long = String(repeating: "x", count: ServerActivity.statementLimit + 100)
        let activity = MySQLActivityPlanner.activity(
            id: 1, user: nil, database: nil, command: "Query", state: nil,
            timeSeconds: nil, info: long)
        XCTAssertEqual(
            activity?.statement,
            String(repeating: "x", count: ServerActivity.statementLimit) + "…")
    }

    func testNumericTextParsing() {
        XCTAssertEqual(MySQLActivityPlanner.uint64("58"), 58)
        XCTAssertEqual(MySQLActivityPlanner.uint64(" 42 "), 42)
        XCTAssertNil(MySQLActivityPlanner.uint64(nil))
        XCTAssertNil(MySQLActivityPlanner.uint64("not-a-number"))
        XCTAssertNil(MySQLActivityPlanner.uint64("-1"))
    }
}
