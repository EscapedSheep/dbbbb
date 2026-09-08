import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Offline coverage for the PostgreSQL DDL reconstruction: catalog query
/// shapes, assembly fidelity (quoting, defaults, NOT NULL, primary key,
/// unique indexes), and the empty-database normalization.
final class PostgresIntrospectionPlannerTests: XCTestCase {
    func testRelationOIDSQLScopesRelkindByObjectKind() {
        XCTAssertTrue(PostgresIntrospectionPlanner.relationOIDSQL(isView: false).contains("'r', 'p', 'f'"))
        XCTAssertTrue(PostgresIntrospectionPlanner.relationOIDSQL(isView: true).contains("'v', 'm'"))
        // Names always cross as binds, never interpolated.
        XCTAssertTrue(PostgresIntrospectionPlanner.relationOIDSQL(isView: false).contains("n.nspname = $1"))
        XCTAssertTrue(PostgresIntrospectionPlanner.relationOIDSQL(isView: false).contains("c.relname = $2"))
    }

    func testCatalogQueriesTargetTheRelationOID() {
        XCTAssertTrue(PostgresIntrospectionPlanner.columnListingSQL(relationOID: 42).contains("a.attrelid = 42"))
        XCTAssertTrue(PostgresIntrospectionPlanner.primaryKeySQL(relationOID: 42).contains("con.conrelid = 42"))
        XCTAssertTrue(PostgresIntrospectionPlanner.uniqueIndexSQL(relationOID: 42).contains("i.indrelid = 42"))
        XCTAssertEqual(
            PostgresIntrospectionPlanner.viewDefinitionSQL(relationOID: 42),
            "SELECT pg_catalog.pg_get_viewdef(42, true)")
    }

    func testCreateTableStatementAssembly() throws {
        let statement = try PostgresIntrospectionPlanner.createTableStatement(
            schema: "public", name: "users",
            columns: [
                PostgresIntrospectionColumn(
                    name: "id", type: "bigint", notNull: true, defaultExpression: nil),
                PostgresIntrospectionColumn(
                    name: "email", type: "text", notNull: true,
                    defaultExpression: "'unknown'::text"),
                PostgresIntrospectionColumn(
                    name: "nick\"name", type: "character varying(40)", notNull: false,
                    defaultExpression: nil),
            ],
            primaryKey: (constraintName: "users_pkey", columns: ["id"]),
            uniqueIndexDefinitions: [
                "CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email)"
            ])
        XCTAssertEqual(statement, """
            CREATE TABLE "public"."users" (
                "id" bigint NOT NULL,
                "email" text DEFAULT 'unknown'::text NOT NULL,
                "nick""name" character varying(40),
                CONSTRAINT "users_pkey" PRIMARY KEY ("id")
            );

            CREATE UNIQUE INDEX users_email_key ON public.users USING btree (email);
            """)
    }

    func testCreateTableStatementWithoutPrimaryKeyOrIndexes() throws {
        let statement = try PostgresIntrospectionPlanner.createTableStatement(
            schema: "s", name: "t",
            columns: [PostgresIntrospectionColumn(
                name: "note", type: "text", notNull: false, defaultExpression: nil)],
            primaryKey: nil, uniqueIndexDefinitions: [])
        XCTAssertEqual(statement, """
            CREATE TABLE "s"."t" (
                "note" text
            );
            """)
    }

    func testCreateTableStatementRejectsEmptyColumns() {
        XCTAssertThrowsError(try PostgresIntrospectionPlanner.createTableStatement(
            schema: "s", name: "t", columns: [], primaryKey: nil,
            uniqueIndexDefinitions: []))
    }

    func testCreateTableStatementRejectsNullBytesInIdentifiers() {
        XCTAssertThrowsError(try PostgresIntrospectionPlanner.createTableStatement(
            schema: "s", name: "ta\0ble",
            columns: [PostgresIntrospectionColumn(
                name: "c", type: "text", notNull: false, defaultExpression: nil)],
            primaryKey: nil, uniqueIndexDefinitions: []))
    }

    func testCreateViewStatementTrimsServerSemicolon() throws {
        let statement = try PostgresIntrospectionPlanner.createViewStatement(
            schema: "public", name: "active_users",
            definition: " SELECT users.id FROM users WHERE users.is_active;\n")
        XCTAssertEqual(statement, """
            CREATE VIEW "public"."active_users" AS
            SELECT users.id FROM users WHERE users.is_active;
            """)
    }

    func testCreateViewStatementRejectsEmptyDefinition() {
        XCTAssertThrowsError(try PostgresIntrospectionPlanner.createViewStatement(
            schema: "s", name: "v", definition: "  ; "))
    }

    func testEmptyDatabaseFallsBackToMaintenanceDatabase() async throws {
        let adapter = try PostgresAdapter(input: .init(
            name: "t", host: "localhost", username: "u",
            password: "", database: "  ", sslMode: .disable))
        XCTAssertEqual(adapter.profile.database, "postgres")
        await adapter.close()
    }

    func testEmptyHostIsStillRejected() {
        XCTAssertThrowsError(try PostgresAdapter(input: .init(
            name: "t", host: " ", username: "u",
            password: "", database: "db", sslMode: .disable)))
    }
}
