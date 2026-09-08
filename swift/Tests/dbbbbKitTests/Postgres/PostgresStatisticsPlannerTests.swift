import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the PostgreSQL statistics query (ROADMAP M2 ⑩):
/// catalog query shape (binds, never interpolated names) and row parsing
/// (NULL cells, the -1 "never analyzed" sentinel).
final class PostgresStatisticsPlannerTests: XCTestCase {
    func testStatisticsSQLShape() {
        let sql = PostgresStatisticsPlanner.statisticsSQL
        XCTAssertTrue(sql.contains("c.reltuples"))
        XCTAssertTrue(sql.contains("pg_catalog.pg_total_relation_size(c.oid)"))
        XCTAssertTrue(sql.contains("pg_catalog.pg_indexes_size(c.oid)"))
        // Names always cross as binds, never interpolated.
        XCTAssertTrue(sql.contains("n.nspname = $1"))
        XCTAssertTrue(sql.contains("c.relname = $2"))
        // Tables (incl. partitioned/foreign) and views are in scope.
        XCTAssertTrue(sql.contains("'r', 'p', 'f', 'v', 'm'"))
    }

    func testStatisticsPassThrough() {
        let stats = PostgresStatisticsPlanner.statistics(
            reltuples: 1_000, totalBytes: 65_536, indexBytes: 16_384)
        XCTAssertEqual(stats.estimatedRows, 1_000)
        XCTAssertEqual(stats.totalBytes, 65_536)
        XCTAssertEqual(stats.indexBytes, 16_384)
        XCTAssertTrue(stats.extras.isEmpty)
    }

    /// reltuples = -1 means the table was never analyzed: the estimate is
    /// unknown (nil), not zero.
    func testNegativeReltuplesMeansUnknownEstimate() {
        let stats = PostgresStatisticsPlanner.statistics(
            reltuples: -1, totalBytes: 0, indexBytes: 0)
        XCTAssertNil(stats.estimatedRows)
        XCTAssertEqual(stats.totalBytes, 0)
    }

    func testNullCellsMapToNil() {
        let stats = PostgresStatisticsPlanner.statistics(
            reltuples: nil, totalBytes: nil, indexBytes: nil)
        XCTAssertNil(stats.estimatedRows)
        XCTAssertNil(stats.totalBytes)
        XCTAssertNil(stats.indexBytes)
    }
}
