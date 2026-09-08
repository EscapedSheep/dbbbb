import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Foreign-key metadata SQL + parsing for MySQL (ROADMAP M1 ⑤): the query is
/// parameterized and qualified by the object's schema, referenced rows carry
/// their own schema (server-wide compatible), and referenced ids come from
/// the same `MySQLObjectRef` codec `listObjects` uses.
final class MySQLForeignKeyPlannerTests: XCTestCase {
    func testQueryIsParameterizedAndSchemaQualified() {
        let sql = MySQLForeignKeyPlanner.listForeignKeysSQL
        XCTAssertTrue(sql.contains("TABLE_SCHEMA = ?"))
        XCTAssertTrue(sql.contains("TABLE_NAME = ?"))
        XCTAssertTrue(sql.contains("CONSTRAINT_NAME <> 'PRIMARY'"))
        XCTAssertTrue(sql.contains("REFERENCED_TABLE_NAME IS NOT NULL"))
        XCTAssertTrue(sql.contains("REFERENCED_TABLE_SCHEMA"))
        XCTAssertTrue(sql.contains("ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION"))
    }

    func testSingleColumnForeignKeyParses() throws {
        let keys = try MySQLForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "orders_ibfk_1", column: "user_id",
             referencedSchema: "shop", referencedTable: "users", referencedColumn: "id"),
        ])
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["user_id"])
        XCTAssertEqual(keys[0].referencedColumns, ["id"])
        let expectedRef = MySQLObjectRef(kind: .table, database: "shop", name: "users")
        XCTAssertEqual(keys[0].referencedObject.id, expectedRef.id)
        XCTAssertEqual(
            keys[0].referencedObject.parentID,
            MySQLObjectRef(kind: .database, database: "shop", name: nil).id)
        XCTAssertEqual(keys[0].referencedObject.kind, .table)
        XCTAssertEqual(MySQLObjectRef(id: keys[0].referencedObject.id), expectedRef)
    }

    /// Multi-column keys group by constraint name with ordinal pairing, and a
    /// referenced schema different from the object's schema (cross-schema or
    /// server-wide connection) stays on the referenced id.
    func testMultiColumnAndCrossSchemaGroup() throws {
        let keys = try MySQLForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "lines_ibfk_1", column: "order_org",
             referencedSchema: "sales", referencedTable: "orders", referencedColumn: "org_id"),
            (constraint: "lines_ibfk_1", column: "order_no",
             referencedSchema: "sales", referencedTable: "orders", referencedColumn: "order_no"),
            (constraint: "lines_ibfk_2", column: "owner_id",
             referencedSchema: "shop", referencedTable: "users", referencedColumn: "id"),
        ])
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].columns, ["order_org", "order_no"])
        XCTAssertEqual(keys[0].referencedColumns, ["org_id", "order_no"])
        XCTAssertEqual(
            MySQLObjectRef(id: keys[0].referencedObject.id),
            MySQLObjectRef(kind: .table, database: "sales", name: "orders"))
        XCTAssertEqual(keys[1].columns, ["owner_id"])
    }

    func testEmptyRowsYieldNoKeys() throws {
        XCTAssertEqual(try MySQLForeignKeyPlanner.foreignKeys(rows: []), [])
    }

    /// Malformed rows fail closed: empty names, a constraint pointing at two
    /// targets, or a repeated column all refuse the whole result.
    func testMalformedRowsFailClosed() {
        XCTAssertThrowsError(try MySQLForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "", referencedSchema: "s",
             referencedTable: "t", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try MySQLForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t1", referencedColumn: "id"),
            (constraint: "fk", column: "b", referencedSchema: "s",
             referencedTable: "t2", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try MySQLForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t", referencedColumn: "id"),
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t", referencedColumn: "id"),
        ]))
    }
}
