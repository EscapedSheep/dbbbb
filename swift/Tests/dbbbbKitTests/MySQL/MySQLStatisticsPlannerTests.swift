import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the MySQL statistics query (ROADMAP M2 ⑩):
/// information_schema query shape (parameterized, server-wide compatible)
/// and row parsing (NULL/missing stats, numeric text).
final class MySQLStatisticsPlannerTests: XCTestCase {
    func testStatisticsSQLShape() {
        let sql = MySQLStatisticsPlanner.statisticsSQL
        XCTAssertTrue(sql.contains("information_schema.TABLES"))
        XCTAssertTrue(sql.contains("TABLE_ROWS"))
        XCTAssertTrue(sql.contains("DATA_LENGTH"))
        XCTAssertTrue(sql.contains("INDEX_LENGTH"))
        // The numeric columns cross as text so NULLs survive and the binary
        // protocol needs no integer decoding.
        XCTAssertTrue(sql.contains("CAST(TABLE_ROWS AS CHAR)"))
        // Names always cross as binds, never interpolated.
        XCTAssertTrue(sql.contains("TABLE_SCHEMA = ?"))
        XCTAssertTrue(sql.contains("TABLE_NAME = ?"))
    }

    func testStatisticsParseNumericText() {
        let stats = MySQLStatisticsPlanner.statistics(
            rows: "1000", dataBytes: "65536", indexBytes: "16384")
        XCTAssertEqual(stats.estimatedRows, 1_000)
        XCTAssertEqual(stats.totalBytes, 65_536)
        XCTAssertEqual(stats.indexBytes, 16_384)
        XCTAssertTrue(stats.extras.isEmpty)
    }

    /// Views and never-measured tables report NULL stats: nil, not zero.
    func testNullAndMissingStatsAreNil() {
        let stats = MySQLStatisticsPlanner.statistics(rows: nil, dataBytes: nil, indexBytes: nil)
        XCTAssertNil(stats.estimatedRows)
        XCTAssertNil(stats.totalBytes)
        XCTAssertNil(stats.indexBytes)
    }

    func testUnparseableValuesAreNil() {
        XCTAssertNil(MySQLStatisticsPlanner.int64(""))
        XCTAssertNil(MySQLStatisticsPlanner.int64("n/a"))
        XCTAssertNil(MySQLStatisticsPlanner.int64("-5"))
        XCTAssertNil(MySQLStatisticsPlanner.int64(nil))
        XCTAssertEqual(MySQLStatisticsPlanner.int64(" 42 "), 42)
    }
}
