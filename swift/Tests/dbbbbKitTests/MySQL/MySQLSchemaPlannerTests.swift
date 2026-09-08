import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Structured-schema metadata SQL + parsing for MySQL ("View Schema"): the
/// queries are parameterized and schema-qualified, column rows fold with
/// primary-key ordinals, index rows group with the NON_UNIQUE flag, and the
/// scope-wide foreign-key rows replay the single-table folding per table.
final class MySQLSchemaPlannerTests: XCTestCase {
    // MARK: SQL shape

    func testColumnQueryIsParameterizedAndSchemaQualified() {
        let sql = MySQLSchemaPlanner.listColumnsSQL
        XCTAssertTrue(sql.contains("c.TABLE_SCHEMA = ?"))
        XCTAssertTrue(sql.contains("c.TABLE_NAME = ?"))
        XCTAssertTrue(sql.contains("k.CONSTRAINT_NAME = 'PRIMARY'"))
        XCTAssertTrue(sql.contains("COLUMN_TYPE"))
        XCTAssertTrue(sql.contains("ORDER BY c.ORDINAL_POSITION"))
    }

    func testIndexQueryIsParameterizedAndPositionOrdered() {
        let sql = MySQLSchemaPlanner.listIndexesSQL
        XCTAssertTrue(sql.contains("TABLE_SCHEMA = ?"))
        XCTAssertTrue(sql.contains("TABLE_NAME = ?"))
        XCTAssertTrue(sql.contains("NON_UNIQUE"))
        XCTAssertTrue(sql.contains("ORDER BY INDEX_NAME, SEQ_IN_INDEX"))
    }

    func testAllForeignKeysQueriesCoverScopeWithoutTableFilter() {
        let scoped = MySQLSchemaPlanner.listAllForeignKeysSQL
        XCTAssertTrue(scoped.contains("TABLE_SCHEMA = ?"))
        XCTAssertTrue(scoped.contains("CONSTRAINT_NAME <> 'PRIMARY'"))
        XCTAssertTrue(scoped.contains("REFERENCED_TABLE_NAME IS NOT NULL"))
        // The single-table variant's TABLE_NAME filter must be gone.
        XCTAssertFalse(scoped.contains("TABLE_NAME = ?"))

        let serverWide = MySQLSchemaPlanner.listServerWideForeignKeysSQL
        XCTAssertTrue(serverWide.contains(
            "TABLE_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')"))
        XCTAssertFalse(serverWide.contains("?"))
    }

    // MARK: Columns

    func testColumnsFoldWithPrimaryKeyOrdinals() throws {
        let columns = try MySQLSchemaPlanner.columns(rows: [
            (name: "id", dataType: "bigint unsigned", nullable: "NO", primaryKeyOrdinal: 1),
            (name: "email", dataType: "varchar(255)", nullable: "NO", primaryKeyOrdinal: 0),
            (name: "deleted_at", dataType: "datetime", nullable: "YES", primaryKeyOrdinal: 0),
        ])
        XCTAssertEqual(columns.map(\.name), ["id", "email", "deleted_at"])
        XCTAssertTrue(columns[0].isPrimaryKey)
        XCTAssertFalse(columns[0].nullable)
        XCTAssertEqual(columns[1].dataType, "varchar(255)")
        XCTAssertTrue(columns[2].nullable)
    }

    func testCompositePrimaryKeyKeepsOrdinals() throws {
        let columns = try MySQLSchemaPlanner.columns(rows: [
            (name: "org_id", dataType: "int", nullable: "NO", primaryKeyOrdinal: 1),
            (name: "order_no", dataType: "int", nullable: "NO", primaryKeyOrdinal: 2),
        ])
        XCTAssertEqual(columns.map(\.primaryKeyOrdinal), [1, 2])
    }

    func testMalformedColumnRowsFailClosed() {
        XCTAssertThrowsError(try MySQLSchemaPlanner.columns(rows: [
            (name: "", dataType: "int", nullable: "NO", primaryKeyOrdinal: 0),
        ]))
        XCTAssertThrowsError(try MySQLSchemaPlanner.columns(rows: [
            (name: "a", dataType: "int", nullable: "MAYBE", primaryKeyOrdinal: 0),
        ]))
        XCTAssertThrowsError(try MySQLSchemaPlanner.columns(rows: [
            (name: "a", dataType: "int", nullable: "NO", primaryKeyOrdinal: 0),
            (name: "a", dataType: "int", nullable: "NO", primaryKeyOrdinal: 0),
        ]))
    }

    // MARK: Indexes

    func testIndexesGroupWithUniqueFlagAndPositionedColumns() throws {
        let indexes = try MySQLSchemaPlanner.indexes(rows: [
            (name: "PRIMARY", nonUnique: "0", column: "id"),
            (name: "orders_org_no_idx", nonUnique: "1", column: "org_id"),
            (name: "orders_org_no_idx", nonUnique: "1", column: "order_no"),
            (name: "users_email_key", nonUnique: "0", column: "email"),
        ])
        XCTAssertEqual(indexes.count, 3)
        XCTAssertEqual(indexes[0].name, "PRIMARY")
        XCTAssertTrue(indexes[0].isUnique)
        XCTAssertEqual(indexes[1].columns, ["org_id", "order_no"])
        XCTAssertFalse(indexes[1].isUnique)
        XCTAssertTrue(indexes[2].isUnique)
    }

    func testMalformedIndexRowsFailClosed() {
        XCTAssertThrowsError(try MySQLSchemaPlanner.indexes(rows: [
            (name: "idx", nonUnique: "2", column: "a"),
        ]))
        XCTAssertThrowsError(try MySQLSchemaPlanner.indexes(rows: [
            (name: "idx", nonUnique: "0", column: "a"),
            (name: "idx", nonUnique: "1", column: "b"),
        ]))
    }

    // MARK: Scope-wide foreign keys

    func testAllForeignKeysGroupPerSourceTable() throws {
        let relations = try MySQLSchemaPlanner.allForeignKeys(rows: [
            (schema: "shop", table: "orders", constraint: "orders_ibfk_1",
             column: "user_id", referencedSchema: "shop", referencedTable: "users",
             referencedColumn: "id"),
            (schema: "shop", table: "lines", constraint: "lines_ibfk_1",
             column: "order_org", referencedSchema: "sales", referencedTable: "orders",
             referencedColumn: "org_id"),
            (schema: "shop", table: "lines", constraint: "lines_ibfk_1",
             column: "order_no", referencedSchema: "sales", referencedTable: "orders",
             referencedColumn: "order_no"),
        ])
        XCTAssertEqual(relations.count, 2)

        XCTAssertEqual(relations[0].object.name, "orders")
        XCTAssertEqual(relations[0].foreignKey.columns, ["user_id"])
        XCTAssertEqual(
            MySQLObjectRef(id: relations[0].object.id),
            MySQLObjectRef(kind: .table, database: "shop", name: "orders"))
        XCTAssertEqual(
            MySQLObjectRef(id: relations[0].foreignKey.referencedObject.id),
            MySQLObjectRef(kind: .table, database: "shop", name: "users"))

        // The multi-column key keeps its ordinal pairing, cross-schema.
        XCTAssertEqual(relations[1].object.name, "lines")
        XCTAssertEqual(relations[1].foreignKey.columns, ["order_org", "order_no"])
        XCTAssertEqual(relations[1].foreignKey.referencedColumns, ["org_id", "order_no"])
        XCTAssertEqual(
            MySQLObjectRef(id: relations[1].foreignKey.referencedObject.id),
            MySQLObjectRef(kind: .table, database: "sales", name: "orders"))
    }

    func testAllForeignKeysEmptyRowsYieldNoEdges() throws {
        XCTAssertEqual(try MySQLSchemaPlanner.allForeignKeys(rows: []), [])
    }

    func testAllForeignKeysMalformedRowsFailClosed() {
        XCTAssertThrowsError(try MySQLSchemaPlanner.allForeignKeys(rows: [
            (schema: "s", table: "", constraint: "fk", column: "c",
             referencedSchema: "s", referencedTable: "u", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try MySQLSchemaPlanner.allForeignKeys(rows: [
            (schema: "s", table: "t", constraint: "fk", column: "a",
             referencedSchema: "s", referencedTable: "u1", referencedColumn: "id"),
            (schema: "s", table: "t", constraint: "fk", column: "b",
             referencedSchema: "s", referencedTable: "u2", referencedColumn: "id"),
        ]))
    }
}
