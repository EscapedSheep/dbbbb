import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Foreign-key metadata SQL + parsing for PostgreSQL (ROADMAP M1 ⑤): the
/// query is parameterized and constrained to the object's schema, and rows
/// fold into grouped keys whose referenced ids round-trip through
/// `PostgresObjectIDCodec`.
final class PostgresForeignKeyPlannerTests: XCTestCase {
    func testQueryIsParameterizedAndSchemaConstrained() {
        let sql = PostgresForeignKeyPlanner.listForeignKeysSQL
        XCTAssertTrue(sql.contains("con.contype = 'f'"))
        XCTAssertTrue(sql.contains("n.nspname = $1"))
        XCTAssertTrue(sql.contains("c.relname = $2"))
        // conkey/confkey pairing by ordinal keeps multi-column keys aligned.
        XCTAssertTrue(sql.contains("unnest(con.conkey, con.confkey)"))
        XCTAssertTrue(sql.contains("ORDER BY con.conname, u.ord"))
    }

    func testSingleColumnForeignKeyParses() throws {
        let keys = try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "orders_user_id_fkey", column: "user_id",
             referencedSchema: "public", referencedTable: "users",
             referencedKind: "r", referencedColumn: "id"),
        ])
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["user_id"])
        XCTAssertEqual(keys[0].referencedColumns, ["id"])
        // The referenced id is exactly what listObjects would emit, so it
        // previews directly.
        let expectedRef = PostgresObjectRef(kind: .table, schema: "public", name: "users")
        XCTAssertEqual(keys[0].referencedObject.id, PostgresObjectIDCodec.encode(expectedRef))
        XCTAssertEqual(
            keys[0].referencedObject.parentID,
            PostgresObjectIDCodec.encode(PostgresObjectRef(kind: .schema, schema: "public", name: nil)))
        XCTAssertEqual(keys[0].referencedObject.name, "users")
        XCTAssertEqual(keys[0].referencedObject.kind, .table)
        XCTAssertEqual(PostgresObjectIDCodec.decode(keys[0].referencedObject.id), expectedRef)
    }

    /// One constraint over two columns groups into a single key, keeping the
    /// ordinal pairing of constrained and referenced columns.
    func testMultiColumnForeignKeyGroupsByConstraint() throws {
        let keys = try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "lines_order_fkey", column: "order_org",
             referencedSchema: "sales", referencedTable: "orders",
             referencedKind: "p", referencedColumn: "org_id"),
            (constraint: "lines_order_fkey", column: "order_no",
             referencedSchema: "sales", referencedTable: "orders",
             referencedKind: "p", referencedColumn: "order_no"),
            (constraint: "lines_owner_fkey", column: "owner_id",
             referencedSchema: "public", referencedTable: "users",
             referencedKind: "r", referencedColumn: "id"),
        ])
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0].columns, ["order_org", "order_no"])
        XCTAssertEqual(keys[0].referencedColumns, ["org_id", "order_no"])
        XCTAssertEqual(keys[0].referencedObject.kind, .table)
        XCTAssertEqual(keys[1].columns, ["owner_id"])
    }

    /// Cross-schema references carry the referenced schema in the id.
    func testCrossSchemaReferenceRoundTrips() throws {
        let keys = try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "tenant_id",
             referencedSchema: "tenants", referencedTable: "tenant",
             referencedKind: "r", referencedColumn: "id"),
        ])
        XCTAssertEqual(
            PostgresObjectIDCodec.decode(keys[0].referencedObject.id),
            PostgresObjectRef(kind: .table, schema: "tenants", name: "tenant"))
    }

    func testEmptyRowsYieldNoKeys() throws {
        XCTAssertEqual(try PostgresForeignKeyPlanner.foreignKeys(rows: []), [])
    }

    /// Malformed rows fail closed: empty names, a referenced relkind outside
    /// the known set, a constraint pointing at two targets, or a repeated
    /// column all refuse the whole result.
    func testMalformedRowsFailClosed() {
        XCTAssertThrowsError(try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "", column: "c", referencedSchema: "s",
             referencedTable: "t", referencedKind: "r", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "c", referencedSchema: "s",
             referencedTable: "t", referencedKind: "S", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t1", referencedKind: "r", referencedColumn: "id"),
            (constraint: "fk", column: "b", referencedSchema: "s",
             referencedTable: "t2", referencedKind: "r", referencedColumn: "id"),
        ]))
        XCTAssertThrowsError(try PostgresForeignKeyPlanner.foreignKeys(rows: [
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t", referencedKind: "r", referencedColumn: "id"),
            (constraint: "fk", column: "a", referencedSchema: "s",
             referencedTable: "t", referencedKind: "r", referencedColumn: "id"),
        ]))
    }
}
