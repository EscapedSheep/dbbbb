import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Structured-schema metadata SQL + parsing for PostgreSQL ("View Schema"):
/// the queries are parameterized and schema-qualified, column rows fold with
/// primary-key ordinals, index rows group with the unique flag, and the
/// database-wide foreign-key rows replay the single-table folding per table.
final class PostgresSchemaPlannerTests: XCTestCase {
    // MARK: SQL shape

    func testColumnQueryIsParameterizedAndSchemaQualified() {
        let sql = PostgresSchemaPlanner.listColumnsSQL
        XCTAssertTrue(sql.contains("n.nspname = $1"))
        XCTAssertTrue(sql.contains("c.relname = $2"))
        XCTAssertTrue(sql.contains("con.contype = 'p'"))
        XCTAssertTrue(sql.contains("NOT a.attisdropped"))
        XCTAssertTrue(sql.contains("ORDER BY a.attnum"))
    }

    func testIndexQueryIsParameterizedAndOrdinalOrdered() {
        let sql = PostgresSchemaPlanner.listIndexesSQL
        XCTAssertTrue(sql.contains("n.nspname = $1"))
        XCTAssertTrue(sql.contains("t.relname = $2"))
        XCTAssertTrue(sql.contains("ix.indisunique"))
        XCTAssertTrue(sql.contains("ORDER BY i.relname, k.ord"))
    }

    func testAllForeignKeysQueryCoversUserSchemasWithoutTableFilter() {
        let sql = PostgresSchemaPlanner.listAllForeignKeysSQL
        XCTAssertTrue(sql.contains("con.contype = 'f'"))
        XCTAssertTrue(sql.contains("n.nspname <> 'information_schema'"))
        XCTAssertTrue(sql.contains("n.nspname !~ '^pg_'"))
        // No binds: the whole-database overview is unparameterized.
        XCTAssertFalse(sql.contains("$1"))
        XCTAssertTrue(sql.contains("ORDER BY n.nspname, c.relname, con.conname, u.ord"))
    }

    // MARK: Columns

    func testColumnsFoldWithPrimaryKeyOrdinals() throws {
        let columns = try PostgresSchemaPlanner.columns(rows: [
            (name: "id", dataType: "bigint", nullable: false, primaryKeyOrdinal: 1),
            (name: "email", dataType: "text", nullable: false, primaryKeyOrdinal: 0),
            (name: "deleted_at", dataType: "timestamp with time zone", nullable: true,
             primaryKeyOrdinal: 0),
        ])
        XCTAssertEqual(columns.map(\.name), ["id", "email", "deleted_at"])
        XCTAssertTrue(columns[0].isPrimaryKey)
        XCTAssertEqual(columns[0].primaryKeyOrdinal, 1)
        XCTAssertFalse(columns[0].nullable)
        XCTAssertFalse(columns[1].isPrimaryKey)
        XCTAssertTrue(columns[2].nullable)
    }

    func testCompositePrimaryKeyKeepsOrdinals() throws {
        let columns = try PostgresSchemaPlanner.columns(rows: [
            (name: "org_id", dataType: "integer", nullable: false, primaryKeyOrdinal: 1),
            (name: "order_no", dataType: "integer", nullable: false, primaryKeyOrdinal: 2),
        ])
        XCTAssertEqual(columns.map(\.primaryKeyOrdinal), [1, 2])
        XCTAssertTrue(columns.allSatisfy(\.isPrimaryKey))
    }

    func testMalformedColumnRowsFailClosed() {
        XCTAssertThrowsError(try PostgresSchemaPlanner.columns(rows: [
            (name: "", dataType: "text", nullable: true, primaryKeyOrdinal: 0),
        ]))
        XCTAssertThrowsError(try PostgresSchemaPlanner.columns(rows: [
            (name: "a", dataType: "text", nullable: true, primaryKeyOrdinal: 0),
            (name: "a", dataType: "text", nullable: true, primaryKeyOrdinal: 0),
        ]))
    }

    // MARK: Indexes

    func testIndexesGroupWithUniqueFlagAndOrdinalColumns() throws {
        let indexes = try PostgresSchemaPlanner.indexes(rows: [
            (name: "users_email_key", isUnique: true, column: "email"),
            (name: "orders_org_no_idx", isUnique: false, column: "org_id"),
            (name: "orders_org_no_idx", isUnique: false, column: "order_no"),
        ])
        XCTAssertEqual(indexes.count, 2)
        XCTAssertEqual(indexes[0].name, "users_email_key")
        XCTAssertTrue(indexes[0].isUnique)
        XCTAssertEqual(indexes[0].columns, ["email"])
        XCTAssertEqual(indexes[1].columns, ["org_id", "order_no"])
        XCTAssertFalse(indexes[1].isUnique)
    }

    func testMalformedIndexRowsFailClosed() {
        XCTAssertThrowsError(try PostgresSchemaPlanner.indexes(rows: [
            (name: "idx", isUnique: true, column: ""),
        ]))
        // The same index reported both unique and not: catalog corruption.
        XCTAssertThrowsError(try PostgresSchemaPlanner.indexes(rows: [
            (name: "idx", isUnique: true, column: "a"),
            (name: "idx", isUnique: false, column: "b"),
        ]))
    }

    // MARK: Database-wide foreign keys

    func testAllForeignKeysGroupPerSourceTable() throws {
        let relations = try PostgresSchemaPlanner.allForeignKeys(rows: [
            (schema: "shop", table: "orders", constraint: "orders_user_id_fkey",
             column: "user_id", referencedSchema: "shop", referencedTable: "users",
             referencedKind: "r", referencedColumn: "id"),
            (schema: "shop", table: "lines", constraint: "lines_order_fkey",
             column: "order_org", referencedSchema: "sales", referencedTable: "orders",
             referencedKind: "p", referencedColumn: "org_id"),
            (schema: "shop", table: "lines", constraint: "lines_order_fkey",
             column: "order_no", referencedSchema: "sales", referencedTable: "orders",
             referencedKind: "p", referencedColumn: "order_no"),
        ])
        XCTAssertEqual(relations.count, 2)

        XCTAssertEqual(relations[0].object.name, "orders")
        XCTAssertEqual(relations[0].foreignKey.columns, ["user_id"])
        XCTAssertEqual(relations[0].foreignKey.referencedColumns, ["id"])
        XCTAssertEqual(
            PostgresObjectIDCodec.decode(relations[0].object.id),
            PostgresObjectRef(kind: .table, schema: "shop", name: "orders"))
        XCTAssertEqual(
            PostgresObjectIDCodec.decode(relations[0].foreignKey.referencedObject.id),
            PostgresObjectRef(kind: .table, schema: "shop", name: "users"))

        // The multi-column key keeps its ordinal pairing, cross-schema.
        XCTAssertEqual(relations[1].object.name, "lines")
        XCTAssertEqual(relations[1].foreignKey.columns, ["order_org", "order_no"])
        XCTAssertEqual(relations[1].foreignKey.referencedColumns, ["org_id", "order_no"])
        XCTAssertEqual(
            PostgresObjectIDCodec.decode(relations[1].foreignKey.referencedObject.id),
            PostgresObjectRef(kind: .table, schema: "sales", name: "orders"))
    }

    func testAllForeignKeysEmptyRowsYieldNoEdges() throws {
        XCTAssertEqual(try PostgresSchemaPlanner.allForeignKeys(rows: []), [])
    }

    func testAllForeignKeysMalformedRowsFailClosed() {
        XCTAssertThrowsError(try PostgresSchemaPlanner.allForeignKeys(rows: [
            (schema: "", table: "t", constraint: "fk", column: "c",
             referencedSchema: "s", referencedTable: "u", referencedKind: "r",
             referencedColumn: "id"),
        ]))
        // A constraint pointing at two targets is rejected by the replayed
        // single-table folding.
        XCTAssertThrowsError(try PostgresSchemaPlanner.allForeignKeys(rows: [
            (schema: "s", table: "t", constraint: "fk", column: "a",
             referencedSchema: "s", referencedTable: "u1", referencedKind: "r",
             referencedColumn: "id"),
            (schema: "s", table: "t", constraint: "fk", column: "b",
             referencedSchema: "s", referencedTable: "u2", referencedKind: "r",
             referencedColumn: "id"),
        ]))
    }
}
