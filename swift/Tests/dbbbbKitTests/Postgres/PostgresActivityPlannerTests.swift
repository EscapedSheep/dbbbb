import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the PostgreSQL activity query (ROADMAP M2 ⑨): the
/// pg_stat_activity query shape (own backend excluded, statement excerpted
/// server-side) and row parsing (NULL cells, the age text, missing pid).
final class PostgresActivityPlannerTests: XCTestCase {
    func testListActivitySQLShape() {
        let sql = PostgresActivityPlanner.listActivitySQL
        XCTAssertTrue(sql.contains("pg_catalog.pg_stat_activity"))
        XCTAssertTrue(sql.contains("usename"))
        XCTAssertTrue(sql.contains("datname"))
        XCTAssertTrue(sql.contains("state"))
        // The statement is excerpted server-side to the shared limit.
        XCTAssertTrue(sql.contains("left(query, \(ServerActivity.statementLimit))"))
        // Our own backend is excluded from the kill list.
        XCTAssertTrue(sql.contains("pid <> pg_catalog.pg_backend_pid()"))
        // The age is server-computed from query_start and crosses as text.
        XCTAssertTrue(sql.contains("EXTRACT(EPOCH FROM (now() - query_start))::text"))
    }

    func testFullRowMaps() {
        let activity = PostgresActivityPlanner.activity(
            pid: "8124", user: "etl", database: "warehouse",
            state: "active", ageSeconds: 12.5,
            statement: "select pg_sleep(60)")
        XCTAssertEqual(activity?.id, "8124")
        XCTAssertEqual(activity?.user, "etl")
        XCTAssertEqual(activity?.database, "warehouse")
        XCTAssertEqual(activity?.state, "active")
        XCTAssertEqual(activity?.statement, "select pg_sleep(60)")
        XCTAssertEqual(activity?.age, .milliseconds(12_500))
    }

    /// Missing pid → no kill handle → the row is dropped.
    func testMissingPIDDropsTheRow() {
        XCTAssertNil(PostgresActivityPlanner.activity(
            pid: nil, user: "u", database: "d", state: "active", ageSeconds: 1,
            statement: "select 1"))
        XCTAssertNil(PostgresActivityPlanner.activity(
            pid: "", user: "u", database: "d", state: "active", ageSeconds: 1,
            statement: "select 1"))
    }

    /// Idle backends: NULL age/statement/state survive as nil, never as
    /// misleading zeros.
    func testNullCellsMapToNil() {
        let activity = PostgresActivityPlanner.activity(
            pid: "8310", user: nil, database: nil, state: nil,
            ageSeconds: nil, statement: nil)
        XCTAssertEqual(activity?.id, "8310")
        XCTAssertNil(activity?.user)
        XCTAssertNil(activity?.database)
        XCTAssertNil(activity?.state)
        XCTAssertNil(activity?.statement)
        XCTAssertNil(activity?.age)
    }

    func testAgeTextParsing() {
        XCTAssertEqual(PostgresActivityPlanner.ageSeconds("12.5"), 12.5)
        XCTAssertEqual(PostgresActivityPlanner.ageSeconds("0"), 0)
        XCTAssertNil(PostgresActivityPlanner.ageSeconds(nil))
        XCTAssertNil(PostgresActivityPlanner.ageSeconds("not-a-number"))
        XCTAssertNil(PostgresActivityPlanner.ageSeconds("-1"))
    }

    /// Compile-time conformance: PG/MySQL/Mongo opt into the capability.
    func testConformingEngines() {
        func require(_: any SupportsServerActivity.Type) {}
        require(PostgresAdapter.self)
        require(MySQLAdapter.self)
        require(MongoAdapter.self)
    }
}
