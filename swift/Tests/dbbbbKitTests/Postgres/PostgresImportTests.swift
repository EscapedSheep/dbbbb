import XCTest
@testable import dbbbbKit

/// Pure-planner tests for PostgreSQL CSV imports (offline; no server).
final class PostgresImportTests: XCTestCase {
    func testBatchSizeRespectsParameterLimit() throws {
        XCTAssertEqual(try PostgresImportPlanner.batchSize(columnCount: 1), 500)
        XCTAssertEqual(try PostgresImportPlanner.batchSize(columnCount: 10), 500)
        // 65 535 / 200 = 327 full rows per batch.
        XCTAssertEqual(try PostgresImportPlanner.batchSize(columnCount: 200), 327)
        // One column more than the parameter limit leaves no room for a row.
        XCTAssertThrowsError(try PostgresImportPlanner.batchSize(columnCount: 65_536))
        XCTAssertThrowsError(try PostgresImportPlanner.batchSize(columnCount: 0))
    }

    func testInsertStatementShape() throws {
        let sql = try PostgresImportPlanner.insertStatement(
            schema: "public", table: "people", columns: ["id", "na\"me"], rowCount: 2)
        XCTAssertEqual(
            sql,
            """
            INSERT INTO "public"."people"
            ("id", "na""me")
            VALUES ($1, $2),
                   ($3, $4);
            """)
    }

    func testInsertStatementRejectsInvalidBatches() {
        XCTAssertThrowsError(try PostgresImportPlanner.insertStatement(
            schema: "public", table: "t", columns: ["a"], rowCount: 0))
        XCTAssertThrowsError(try PostgresImportPlanner.insertStatement(
            schema: "public", table: "t", columns: [], rowCount: 1))
        XCTAssertThrowsError(try PostgresImportPlanner.insertStatement(
            schema: "public", table: "t", columns: ["a", "b"], rowCount: 40_000))
        XCTAssertThrowsError(try PostgresImportPlanner.insertStatement(
            schema: "bad\0", table: "t", columns: ["a"], rowCount: 1))
    }
}
