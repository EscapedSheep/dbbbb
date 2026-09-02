import XCTest
@testable import dbbbbKit

/// Pure-planner tests for MySQL CSV imports (offline; no server).
final class MySQLImportTests: XCTestCase {
    func testBatchSizeRespectsParameterLimit() throws {
        XCTAssertEqual(try MySQLImportPlanner.batchSize(columnCount: 1), 500)
        XCTAssertEqual(try MySQLImportPlanner.batchSize(columnCount: 200), 327)
        XCTAssertThrowsError(try MySQLImportPlanner.batchSize(columnCount: 65_536))
        XCTAssertThrowsError(try MySQLImportPlanner.batchSize(columnCount: 0))
    }

    func testInsertStatementShape() throws {
        let sql = try MySQLImportPlanner.insertStatement(
            database: "shop", table: "peo`ple", columns: ["id", "name"], rowCount: 2)
        XCTAssertEqual(
            sql,
            """
            INSERT INTO `shop`.`peo``ple`
            (`id`, `name`)
            VALUES (?, ?),
                   (?, ?)
            """)
    }

    func testInsertStatementRejectsInvalidBatches() {
        XCTAssertThrowsError(try MySQLImportPlanner.insertStatement(
            database: "d", table: "t", columns: ["a"], rowCount: 0))
        XCTAssertThrowsError(try MySQLImportPlanner.insertStatement(
            database: "d", table: "t", columns: [], rowCount: 1))
        XCTAssertThrowsError(try MySQLImportPlanner.insertStatement(
            database: "d", table: "t", columns: ["a", "b"], rowCount: 40_000))
    }
}
