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
}
