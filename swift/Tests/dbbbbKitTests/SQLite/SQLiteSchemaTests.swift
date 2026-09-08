import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Structured-schema introspection against real on-disk databases ("View
/// Schema"): columns with PK ordinals from `pragma_table_info`, indexes from
/// `pragma_index_list`/`pragma_index_info`, foreign keys through the existing
/// per-table read, and the database-wide relationship list.
final class SQLiteSchemaTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase(sql: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-schema-\(UUID().uuidString).sqlite")
        temporaryURLs.append(url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: sql)
        }
        return url.path
    }

    private func makeAdapter(path: String, readOnly: Bool = false) throws -> SQLiteAdapter {
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path, readOnly: readOnly))
        addTeardownBlock {
            await adapter.close()
        }
        return adapter
    }

    private func object(named name: String, kind: DatabaseObjectKind = .table) -> DatabaseObject {
        DatabaseObject(
            id: SQLiteAdapter.objectID(kind: kind, name: name),
            parentID: SQLiteAdapter.objectID(kind: .schema, name: nil),
            name: name,
            kind: kind)
    }

    // MARK: Per-table schema

    func testSchemaReportsColumnsNullabilityAndPrimaryKey() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                email TEXT NOT NULL,
                nickname TEXT);
            """)
        let adapter = try makeAdapter(path: path)
        let schema = try await adapter.schema(for: object(named: "users"))

        XCTAssertEqual(schema.object, object(named: "users"))
        XCTAssertEqual(schema.columns.map(\.name), ["id", "email", "nickname"])
        XCTAssertEqual(schema.columns.map(\.primaryKeyOrdinal), [1, 0, 0])
        XCTAssertTrue(schema.columns[0].isPrimaryKey)
        XCTAssertEqual(schema.columns.map(\.nullable), [false, false, true])
        XCTAssertEqual(schema.columns[1].dataType, "TEXT")
    }

    func testCompositePrimaryKeyKeepsOrdinals() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE lines (
                org_id INTEGER NOT NULL,
                line_no INTEGER NOT NULL,
                label TEXT,
                PRIMARY KEY (org_id, line_no));
            """)
        let adapter = try makeAdapter(path: path)
        let schema = try await adapter.schema(for: object(named: "lines"))
        XCTAssertEqual(schema.columns.map(\.primaryKeyOrdinal), [1, 2, 0])
    }

    func testSchemaReportsIndexesWithUniqueFlag() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL, org INTEGER);
            CREATE UNIQUE INDEX users_email_key ON users (email);
            CREATE INDEX users_org_idx ON users (org, id);
            """)
        let adapter = try makeAdapter(path: path)
        let schema = try await adapter.schema(for: object(named: "users"))

        let byName = Dictionary(schema.indexes.map { ($0.name, $0) }) { first, _ in first }
        // The INTEGER PRIMARY KEY's implicit sqlite_autoindex is filtered by
        // sqlite_master but listed by pragma_index_list; either way the
        // explicit indexes must be present and correct.
        let email = try XCTUnwrap(byName["users_email_key"])
        XCTAssertTrue(email.isUnique)
        XCTAssertEqual(email.columns, ["email"])
        let org = try XCTUnwrap(byName["users_org_idx"])
        XCTAssertFalse(org.isUnique)
        XCTAssertEqual(org.columns, ["org", "id"])
    }

    func testSchemaReportsForeignKeys() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            """)
        let adapter = try makeAdapter(path: path)
        let schema = try await adapter.schema(for: object(named: "orders"))
        XCTAssertEqual(schema.foreignKeys.count, 1)
        XCTAssertEqual(schema.foreignKeys[0].columns, ["user_id"])
        XCTAssertEqual(schema.foreignKeys[0].referencedColumns, ["id"])
        XCTAssertEqual(schema.foreignKeys[0].referencedObject, object(named: "users"))
    }

    /// Views have columns but no indexes or foreign keys.
    func testViewSchemaHasColumnsOnly() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE VIEW user_names AS SELECT id, name FROM users;
            """)
        let adapter = try makeAdapter(path: path)
        let schema = try await adapter.schema(for: object(named: "user_names", kind: .view))
        XCTAssertEqual(schema.columns.map(\.name), ["id", "name"])
        XCTAssertEqual(schema.indexes, [])
        XCTAssertEqual(schema.foreignKeys, [])
    }

    func testNonTableOrViewObjectFailsClosed() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.schema(
                for: DatabaseObject(
                    id: SQLiteAdapter.objectID(kind: .schema, name: nil),
                    parentID: nil, name: "main", kind: .schema))
            XCTFail("schema nodes must fail closed")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testReadOnlyProfileMayReadSchemas() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path, readOnly: true)
        let schema = try await adapter.schema(for: object(named: "t"))
        XCTAssertEqual(schema.columns.count, 1)
    }

    // MARK: Database-wide relationships

    func testAllForeignKeysListsEveryEdge() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            CREATE TABLE lines (
                line_id INTEGER PRIMARY KEY,
                org INTEGER, no INTEGER,
                FOREIGN KEY (org, no) REFERENCES orders (id, user_id));
            CREATE TABLE plain (id INTEGER PRIMARY KEY);
            """)
        let adapter = try makeAdapter(path: path)
        let relations = try await adapter.allForeignKeys()

        XCTAssertEqual(relations.count, 2)
        // Ordered by source table name: lines, orders.
        XCTAssertEqual(relations[0].object, object(named: "lines"))
        XCTAssertEqual(relations[0].foreignKey.columns, ["org", "no"])
        XCTAssertEqual(relations[0].foreignKey.referencedColumns, ["id", "user_id"])
        XCTAssertEqual(relations[0].foreignKey.referencedObject, object(named: "orders"))
        XCTAssertEqual(relations[1].object, object(named: "orders"))
        XCTAssertEqual(relations[1].foreignKey.columns, ["user_id"])
        XCTAssertEqual(relations[1].foreignKey.referencedObject, object(named: "users"))
    }

    func testAllForeignKeysWithoutKeysYieldsEmpty() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE plain (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path)
        let relations = try await adapter.allForeignKeys()
        XCTAssertEqual(relations, [])
    }

    // MARK: Planner edge cases (offline)

    func testColumnPlannerRejectsMalformedRows() {
        XCTAssertThrowsError(try SQLiteSchemaPlanner.columns(rows: [
            (name: "", dataType: "TEXT", notNull: false, primaryKeyOrdinal: 0),
        ]))
        XCTAssertThrowsError(try SQLiteSchemaPlanner.columns(rows: [
            (name: "a", dataType: "TEXT", notNull: false, primaryKeyOrdinal: 0),
            (name: "a", dataType: "TEXT", notNull: false, primaryKeyOrdinal: 0),
        ]))
    }

    /// Expression indexes report no plain columns and fold away rather than
    /// showing up half-described.
    func testIndexPlannerDropsColumnlessIndexes() throws {
        let indexes = try SQLiteSchemaPlanner.indexes(
            rows: [
                (name: "real_idx", isUnique: true),
                (name: "expr_idx", isUnique: false),
            ],
            columns: ["real_idx": ["a"], "expr_idx": []])
        XCTAssertEqual(indexes, [IndexSchema(name: "real_idx", columns: ["a"], isUnique: true)])
    }
}
