import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Foreign-key introspection against real on-disk databases plus the
/// jump-equivalence round trip (ROADMAP M1 ⑤): FK metadata comes from
/// `pragma_foreign_key_list(?)` (implicit-PK references resolved), and an
/// equality-filtered preview of the referenced table returns exactly the row
/// the FK points at.
final class SQLiteForeignKeyTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase(sql: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-fk-\(UUID().uuidString).sqlite")
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

    // MARK: Metadata

    func testSingleColumnForeignKeyRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            """)
        let adapter = try makeAdapter(path: path)
        let keys = try await adapter.foreignKeys(for: object(named: "orders"))
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["user_id"])
        XCTAssertEqual(keys[0].referencedColumns, ["id"])
        XCTAssertEqual(keys[0].referencedObject, object(named: "users"))
    }

    func testMultiColumnForeignKeyKeepsOrdinalPairing() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE orders (org_id INTEGER, order_no INTEGER, PRIMARY KEY (org_id, order_no));
            CREATE TABLE lines (
                line_id INTEGER PRIMARY KEY,
                org INTEGER, no INTEGER,
                FOREIGN KEY (org, no) REFERENCES orders (org_id, order_no));
            """)
        let adapter = try makeAdapter(path: path)
        let keys = try await adapter.foreignKeys(for: object(named: "lines"))
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["org", "no"])
        XCTAssertEqual(keys[0].referencedColumns, ["org_id", "order_no"])
        XCTAssertEqual(keys[0].referencedObject, object(named: "orders"))
    }

    /// `REFERENCES users` without a column list reports a NULL target column;
    /// it resolves to the referenced table's primary key.
    func testImplicitPrimaryKeyReferenceResolves() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users);
            """)
        let adapter = try makeAdapter(path: path)
        let keys = try await adapter.foreignKeys(for: object(named: "orders"))
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["user_id"])
        XCTAssertEqual(keys[0].referencedColumns, ["id"])
    }

    func testTableWithoutForeignKeysYieldsEmpty() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE plain (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path)
        let keys = try await adapter.foreignKeys(for: object(named: "plain"))
        XCTAssertEqual(keys, [])
    }

    /// Lookup is parameterized: a table name with quotes cannot break out.
    func testQuotedNameStaysParameterized() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE "weird ""parent" (id INTEGER PRIMARY KEY);
            CREATE TABLE "weird ""child" (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER REFERENCES "weird ""parent"(id));
            """)
        let adapter = try makeAdapter(path: path)
        let keys = try await adapter.foreignKeys(for: object(named: #"weird "child"#))
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].referencedObject, object(named: #"weird "parent"#))
    }

    func testNonTableObjectFailsClosed() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE t (id INTEGER PRIMARY KEY);
            CREATE VIEW v AS SELECT id FROM t;
            """)
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.foreignKeys(for: object(named: "v", kind: .view))
            XCTFail("views must fail closed")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testReadOnlyProfileMayReadForeignKeys() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            """)
        let adapter = try makeAdapter(path: path, readOnly: true)
        let keys = try await adapter.foreignKeys(for: object(named: "orders"))
        XCTAssertEqual(keys.count, 1)
    }

    // MARK: Planner edge cases (offline)

    /// An implicit reference whose target has no primary key drops the key —
    /// a jump that cannot be aimed is never offered.
    func testUnresolvableImplicitReferenceIsDropped() throws {
        let keys = try SQLiteForeignKeyPlanner.foreignKeys(
            rows: [(id: 0, column: "c", referencedTable: "ghost", referencedColumn: nil)],
            implicitColumns: ["ghost": []])
        XCTAssertEqual(keys, [])
    }

    /// A multi-column implicit reference resolves each leg by key ordinal.
    func testMultiColumnImplicitReferenceResolvesByOrdinal() throws {
        let keys = try SQLiteForeignKeyPlanner.foreignKeys(
            rows: [
                (id: 0, column: "a", referencedTable: "p", referencedColumn: nil),
                (id: 0, column: "b", referencedTable: "p", referencedColumn: nil),
            ],
            implicitColumns: ["p": ["x", "y"]])
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].columns, ["a", "b"])
        XCTAssertEqual(keys[0].referencedColumns, ["x", "y"])
    }

    func testPlannerRejectsMalformedRows() {
        XCTAssertThrowsError(try SQLiteForeignKeyPlanner.foreignKeys(
            rows: [(id: 0, column: "", referencedTable: "t", referencedColumn: "id")],
            implicitColumns: [:]))
        XCTAssertThrowsError(try SQLiteForeignKeyPlanner.foreignKeys(
            rows: [
                (id: 0, column: "a", referencedTable: "t1", referencedColumn: "id"),
                (id: 0, column: "b", referencedTable: "t2", referencedColumn: "id"),
            ],
            implicitColumns: [:]))
    }

    // MARK: Jump equivalence (real database)

    /// The FK jump's exact replay: read the FK value from a child preview,
    /// then preview the referenced table with an equality filter on the
    /// referenced column — the result is exactly the pointed-at row.
    func testJumpEquivalenceViaEqualityFilteredPreview() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id));
            INSERT INTO users (id, name) VALUES (1, 'alice'), (2, 'bob');
            INSERT INTO orders (id, user_id) VALUES (10, 2), (11, 1), (12, 2);
            """)
        let adapter = try makeAdapter(path: path)

        guard case .rows(_, let orderRows, _) = try await adapter.previewObject(
            PreviewRequest(object: object(named: "orders")))
        else { return XCTFail("expected rows") }
        // orders 10: user_id 2 — jump to users row 2.
        let userID = orderRows[0][1]

        guard case .rows(let columns, let rows, _) = try await adapter.previewObject(
            PreviewRequest(
                object: object(named: "users"),
                equalities: [PreviewRequest.Equality(column: "id", value: userID)]))
        else { return XCTFail("expected rows") }
        XCTAssertEqual(columns.map(\.name), ["id", "name"])
        XCTAssertEqual(rows, [[.number(2), .string("bob")]])
    }

    /// Multi-column jumps need every leg; one equality per referenced column
    /// isolates exactly the referenced row.
    func testMultiColumnJumpEquivalence() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE orders (org_id INTEGER, order_no INTEGER, label TEXT,
                PRIMARY KEY (org_id, order_no));
            CREATE TABLE lines (line_id INTEGER PRIMARY KEY, org INTEGER, no INTEGER,
                FOREIGN KEY (org, no) REFERENCES orders (org_id, order_no));
            INSERT INTO orders VALUES (1, 1, 'a'), (1, 2, 'b'), (2, 1, 'c');
            INSERT INTO lines VALUES (100, 1, 2);
            """)
        let adapter = try makeAdapter(path: path)

        guard case .rows(_, let lineRows, _) = try await adapter.previewObject(
            PreviewRequest(object: object(named: "lines")))
        else { return XCTFail("expected rows") }
        let org = lineRows[0][1]
        let no = lineRows[0][2]

        guard case .rows(_, let rows, _) = try await adapter.previewObject(
            PreviewRequest(
                object: object(named: "orders"),
                equalities: [
                    PreviewRequest.Equality(column: "org_id", value: org),
                    PreviewRequest.Equality(column: "order_no", value: no),
                ]))
        else { return XCTFail("expected rows") }
        XCTAssertEqual(rows, [[.number(1), .number(2), .string("b")]])
    }

    /// NULL equality matches NULL rows through `IS NULL`.
    func testNullEqualityPreviewMatchesNullRows() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE notes (id INTEGER PRIMARY KEY, deleted_at TEXT);
            INSERT INTO notes (id, deleted_at) VALUES (1, NULL), (2, 'today');
            """)
        let adapter = try makeAdapter(path: path)
        guard case .rows(_, let rows, _) = try await adapter.previewObject(
            PreviewRequest(
                object: object(named: "notes"),
                equalities: [PreviewRequest.Equality(column: "deleted_at", value: .null)]))
        else { return XCTFail("expected rows") }
        XCTAssertEqual(rows, [[.number(1), .null]])
    }

    /// Text equality does not coerce into other rows' values.
    func testTextEqualityMatchesExactly() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE codes (code TEXT PRIMARY KEY, note TEXT);
            INSERT INTO codes VALUES ('42', 'text forty-two'), ('042', 'other');
            """)
        let adapter = try makeAdapter(path: path)
        guard case .rows(_, let rows, _) = try await adapter.previewObject(
            PreviewRequest(
                object: object(named: "codes"),
                equalities: [PreviewRequest.Equality(column: "code", value: .string("42"))]))
        else { return XCTFail("expected rows") }
        XCTAssertEqual(rows, [[.string("42"), .string("text forty-two")]])
    }
}
