import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Editing tests against real on-disk databases (no server needed, so no
/// environment gating): update/conflict/delete round-trips, NULL-safe
/// matching, storage-class fidelity, read-only refusal, and the view /
/// no-primary-key refusal rules.
final class SQLiteEditingTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase(sql: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-editing-\(UUID().uuidString).sqlite")
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

    private func target(named name: String, kind: DatabaseObjectKind = .table) -> DatabaseObject {
        DatabaseObject(
            id: SQLiteAdapter.objectID(kind: kind, name: name),
            parentID: nil,
            name: name,
            kind: kind)
    }

    private func rows(_ result: QueryResult) throws -> (columns: [ColumnMeta], rows: [[DisplayValue]]) {
        guard case .rows(let columns, let rows, _) = result else {
            throw SQLiteAdapterError("expected rows")
        }
        return (columns, rows)
    }

    private func originalRecord(columns: [ColumnMeta], row: [DisplayValue]) -> [String: DisplayValue] {
        Dictionary(zip(columns, row).map { ($0.0.name, $0.1) }) { first, _ in first }
    }

    private func previewedRecord(
        _ adapter: SQLiteAdapter, table: DatabaseObject, id: Double
    ) async throws -> [String: DisplayValue] {
        let (columns, previewRows) = try rows(try await adapter.previewObject(table))
        guard let row = previewRows.first(where: { $0[0] == .number(id) }) else {
            throw SQLiteAdapterError("inserted row missing from preview")
        }
        return originalRecord(columns: columns, row: row)
    }

    func testUpdateConflictAndDeleteRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                score REAL,
                note TEXT,
                payload BLOB
            );
            INSERT INTO people VALUES
                (1, 'before', 9.5, NULL, X'DEADBEEF'),
                (2, 'sibling', 7.25, 'keep', NULL);
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "people")
        let original = try await previewedRecord(adapter, table: table, id: 1)

        // Update through the editing capability (NULL note becomes text).
        let updated = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["name": .string("after"), "note": .string("ready")])))
        XCTAssertEqual(updated.meta.count, 1)

        // Replaying the stale baseline is an optimistic-concurrency conflict.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: original,
                operation: .update(changed: ["name": .string("stale")])))
            XCTFail("stale baseline must conflict")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        // The sibling row is untouched.
        let check = try rows(try await adapter.execute(
            .sql("SELECT name FROM people WHERE id = 2"), options: ExecuteOptions()))
        XCTAssertEqual(check.rows.first?.first, .string("sibling"))

        // Delete with the current baseline, then replay it for the conflict.
        let freshOriginal = try await previewedRecord(adapter, table: table, id: 1)
        _ = try await adapter.applyDataChange(DataChange(
            object: table, original: freshOriginal, operation: .delete))
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table, original: freshOriginal, operation: .delete))
            XCTFail("deleting a deleted row must conflict")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        let remaining = try rows(try await adapter.execute(
            .sql("SELECT id FROM people ORDER BY id"), options: ExecuteOptions()))
        XCTAssertEqual(remaining.rows.map { $0[0] }, [.number(2)])
    }

    /// Storage-class round-trip proof: a REAL column holding an integral value
    /// (5.0, displayed as 5) and an INTEGER PK must both match exactly under
    /// `IS`, or the optimistic check would misreport a conflict.
    func testUpdatePreservesNumericStorageClasses() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE metrics (
                id INTEGER PRIMARY KEY,
                reading REAL,
                label TEXT
            );
            INSERT INTO metrics VALUES (1, 5.0, 'x');
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "metrics")
        let original = try await previewedRecord(adapter, table: table, id: 1)
        XCTAssertEqual(original["reading"], .number(5))

        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["label": .string("y")])))
        let (columns, resultRows) = try rows(try await adapter.execute(
            .sql("SELECT reading, typeof(reading) FROM metrics"), options: ExecuteOptions()))
        _ = columns
        XCTAssertEqual(resultRows, [[.number(5), .string("real")]])
    }

    func testCompositePrimaryKeyAndWithoutRowID() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE memberships (
                tenant_id INTEGER NOT NULL,
                user_id TEXT NOT NULL,
                role TEXT,
                PRIMARY KEY (tenant_id, user_id)
            ) WITHOUT ROWID;
            INSERT INTO memberships VALUES (7, 'u-1', 'viewer');
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "memberships")
        let original = try await previewedRecord(adapter, table: table, id: 7)

        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["role": .string("admin")])))
        let result = try rows(try await adapter.execute(
            .sql("SELECT role FROM memberships WHERE tenant_id = 7 AND user_id = 'u-1'"),
            options: ExecuteOptions()))
        XCTAssertEqual(result.rows.first?.first, .string("admin"))
    }

    /// Generated columns are excluded from the editable column set (they are
    /// hidden in `pragma_table_xinfo`), so a previewed record containing one
    /// is an unknown field and the change is refused fail-closed — both when
    /// the generated column is the edit target and when it is merely present
    /// in the original snapshot.
    func testGeneratedColumnsAreExcludedFromEditing() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE products (
                id INTEGER PRIMARY KEY,
                name TEXT,
                price REAL,
                taxed REAL GENERATED ALWAYS AS (price * 1.1) VIRTUAL
            );
            INSERT INTO products (id, name, price) VALUES (1, 'pen', 10.0);
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "products")
        let original = try await previewedRecord(adapter, table: table, id: 1)

        let changeSets: [[String: DisplayValue]] = [["taxed": .number(11)], ["name": .string("pencil")]]
        for changed in changeSets {
            do {
                _ = try await adapter.applyDataChange(DataChange(
                    object: table,
                    original: original,
                    operation: .update(changed: changed)))
                XCTFail("records containing generated columns must be refused")
            } catch let error as SQLiteChangePlanError {
                XCTAssertTrue(error.userMessage.contains("unknown table field"), error.userMessage)
            }
        }

        let result = try rows(try await adapter.execute(
            .sql("SELECT name, taxed FROM products WHERE id = 1"), options: ExecuteOptions()))
        XCTAssertEqual(result.rows.first, [.string("pen"), .number(11)])
    }

    func testRefusesViewsAndTablesWithoutPrimaryKey() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE loose (id INTEGER, note TEXT);
            INSERT INTO loose VALUES (1, 'x');
            CREATE VIEW loose_view AS SELECT id, note FROM loose;
            """)
        let adapter = try makeAdapter(path: path)

        // Views are refused by object kind before any SQL runs.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: target(named: "loose_view", kind: .view),
                original: ["id": .number(1), "note": .string("x")],
                operation: .delete))
            XCTFail("views must be refused")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }

        // Tables without a declared primary key are refused at metadata time.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: target(named: "loose"),
                original: ["id": .number(1), "note": .string("x")],
                operation: .delete))
            XCTFail("primary-key-less tables must be refused")
        } catch let error as SQLiteChangePlanError {
            XCTAssertTrue(error.userMessage.contains("primary key"), error.userMessage)
        }
    }

    /// Byte-level lock proof against real SQLite collation semantics: under a
    /// `NOCASE`/`RTRIM` column a concurrent case- or trailing-space-only
    /// rewrite must surface as an optimistic-concurrency conflict, while the
    /// unchanged row still edits cleanly.
    func testCollationInsensitiveRewriteConflicts() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE ci (
                id INTEGER PRIMARY KEY,
                code TEXT COLLATE NOCASE,
                padded TEXT COLLATE RTRIM
            );
            INSERT INTO ci VALUES (1, 'ABC', 'pad'), (2, 'keep', 'keep');
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "ci")
        let original = try await previewedRecord(adapter, table: table, id: 1)
        XCTAssertEqual(original["code"], .string("ABC"))
        XCTAssertEqual(original["padded"], .string("pad"))

        // External writes go through a separate connection, like a concurrent
        // session of another client.
        let external = try DatabaseQueue(path: path)
        func externalWrite(_ sql: String) throws {
            try external.write { db in try db.execute(sql: sql) }
        }

        // Control: the untouched row edits cleanly under the byte-level lock.
        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["code": .string("abc")])))
        let edited = try rows(try await adapter.execute(
            .sql("SELECT code FROM ci WHERE id = 1"), options: ExecuteOptions()))
        XCTAssertEqual(edited.rows.first?.first, .string("abc"))

        // A concurrent case-only rewrite (invisible to NOCASE) must conflict.
        let staleNocase = try await previewedRecord(adapter, table: table, id: 1)
        try externalWrite("UPDATE ci SET code = 'ABC' WHERE id = 1")
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: staleNocase,
                operation: .update(changed: ["code": .string("touched")])))
            XCTFail("case-only rewrite under NOCASE must conflict")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        // A concurrent trailing-space rewrite (invisible to RTRIM) must conflict.
        try externalWrite("UPDATE ci SET padded = 'pad  ' WHERE id = 1")
        let staleRtrim = try await previewedRecord(adapter, table: table, id: 1)
        XCTAssertEqual(staleRtrim["padded"], .string("pad  "))
        try externalWrite("UPDATE ci SET padded = 'pad' WHERE id = 1")
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: staleRtrim,
                operation: .update(changed: ["padded": .string("touched")])))
            XCTFail("trailing-space rewrite under RTRIM must conflict")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        // Deletes are byte-exact too: a stale delete after a case-only
        // rewrite conflicts instead of deleting the changed row.
        try externalWrite("UPDATE ci SET code = 'aBc' WHERE id = 1")
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table, original: staleNocase, operation: .delete))
            XCTFail("stale delete under NOCASE must conflict")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }
        let remaining = try rows(try await adapter.execute(
            .sql("SELECT code FROM ci ORDER BY id"), options: ExecuteOptions()))
        XCTAssertEqual(remaining.rows.map { $0[0] }, [.string("aBc"), .string("keep")])
    }

    func testRejectsReadOnlySessions() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);
            INSERT INTO people VALUES (1, 'before');
            """)
        let adapter = try makeAdapter(path: path, readOnly: true)
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: target(named: "people"),
                original: ["id": .number(1), "name": .string("before")],
                operation: .delete))
            XCTFail("read-only session must refuse row changes")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("read-only"), error.userMessage)
        }
        let result = try rows(try await adapter.execute(
            .sql("SELECT COUNT(*) FROM people"), options: ExecuteOptions()))
        XCTAssertEqual(result.rows.first?.first, .number(1))
    }

    // MARK: - Insert (new row / duplicate row)

    /// Insert round trip: a blank-shaped insert (omitted columns take their
    /// defaults, including the rowid primary key) and a duplicate-shaped one
    /// (explicit values minus the primary key) both land, and the generated
    /// column computes itself.
    func testInsertAndDuplicateRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                score REAL DEFAULT 1.5,
                note TEXT,
                upper_name TEXT GENERATED ALWAYS AS (upper(name)) VIRTUAL
            );
            INSERT INTO people (id, name, note) VALUES (1, 'before', 'keep');
            """)
        let adapter = try makeAdapter(path: path)
        let table = target(named: "people")

        // Insertable columns exclude the generated column; pk ordinal marks id.
        let insertable = try await adapter.insertableColumns(for: table)
        XCTAssertEqual(insertable, [
            InsertableColumn(name: "id", primaryKeyOrdinal: 1),
            InsertableColumn(name: "name", primaryKeyOrdinal: 0),
            InsertableColumn(name: "score", primaryKeyOrdinal: 0),
            InsertableColumn(name: "note", primaryKeyOrdinal: 0),
        ])

        // New row: only the required value; id/score/note take defaults.
        let inserted = try await adapter.applyDataChange(DataChange(
            object: table,
            original: [:],
            operation: .insert(values: ["name": .string("new")])))
        XCTAssertEqual(inserted.meta.count, 1)
        let afterInsert = try rows(try await adapter.execute(
            .sql("SELECT id, name, score, note, upper_name FROM people WHERE name = 'new'"),
            options: ExecuteOptions()))
        XCTAssertEqual(afterInsert.rows, [[.number(2), .string("new"), .number(1.5), .null, .string("NEW")]])

        // Duplicate of row 1: every editable value prefilled except the
        // primary key (blank → server default), so no unique-key collision.
        let duplicate = try await adapter.applyDataChange(DataChange(
            object: table,
            original: [:],
            operation: .insert(values: ["name": .string("before"), "note": .string("keep")])))
        XCTAssertEqual(duplicate.meta.count, 1)
        let all = try rows(try await adapter.execute(
            .sql("SELECT id, name, note FROM people ORDER BY id"), options: ExecuteOptions()))
        XCTAssertEqual(all.rows, [
            [.number(1), .string("before"), .string("keep")],
            [.number(2), .string("new"), .null],
            [.number(3), .string("before"), .string("keep")],
        ])

        // An explicit primary key is honored; reusing one fails server-side
        // with a sanitized constraint error.
        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: [:],
            operation: .insert(values: ["id": .number(9), "name": .string("explicit")])))
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: [:],
                operation: .insert(values: ["id": .number(9), "name": .string("collision")])))
            XCTFail("duplicate primary key must fail")
        } catch let error as SQLiteAdapterError {
            XCTAssertFalse(error.userMessage.contains(path), error.userMessage)
        }
    }

    /// All-omitted values plan as `DEFAULT VALUES`.
    func testInsertDefaultValuesRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE defaults (
                id INTEGER PRIMARY KEY,
                label TEXT DEFAULT 'untitled'
            );
            """)
        let adapter = try makeAdapter(path: path)
        _ = try await adapter.applyDataChange(DataChange(
            object: target(named: "defaults"),
            original: [:],
            operation: .insert(values: [:])))
        let result = try rows(try await adapter.execute(
            .sql("SELECT id, label FROM defaults"), options: ExecuteOptions()))
        XCTAssertEqual(result.rows, [[.number(1), .string("untitled")]])
    }

    /// Inserts reuse the edit gates: read-only sessions, views, and unknown
    /// (e.g. generated) columns are all refused.
    func testInsertFailsClosed() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (
                id INTEGER PRIMARY KEY,
                name TEXT,
                upper_name TEXT GENERATED ALWAYS AS (upper(name)) VIRTUAL
            );
            CREATE VIEW people_view AS SELECT id, name FROM people;
            """)
        let adapter = try makeAdapter(path: path)

        // Generated column as an insert target: unknown field, fail closed.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: target(named: "people"),
                original: [:],
                operation: .insert(values: ["name": .string("x"), "upper_name": .string("X")])))
            XCTFail("generated columns must be refused")
        } catch let error as SQLiteChangePlanError {
            XCTAssertTrue(error.userMessage.contains("unknown table field"), error.userMessage)
        }

        // Views are refused by object kind before any SQL runs.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: target(named: "people_view", kind: .view),
                original: [:],
                operation: .insert(values: ["name": .string("x")])))
            XCTFail("views must be refused")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }

        let readOnlyAdapter = try makeAdapter(path: path, readOnly: true)
        do {
            _ = try await readOnlyAdapter.applyDataChange(DataChange(
                object: target(named: "people"),
                original: [:],
                operation: .insert(values: ["name": .string("x")])))
            XCTFail("read-only session must refuse inserts")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("read-only"), error.userMessage)
        }
        // Reading insertable columns is a read: allowed on read-only sessions.
        let insertable = try await readOnlyAdapter.insertableColumns(for: target(named: "people"))
        XCTAssertEqual(insertable.map(\.name), ["id", "name"])

        let result = try rows(try await adapter.execute(
            .sql("SELECT COUNT(*) FROM people"), options: ExecuteOptions()))
        XCTAssertEqual(result.rows.first?.first, .number(0))
    }
}
