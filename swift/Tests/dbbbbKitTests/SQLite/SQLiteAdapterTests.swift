import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Builds a real on-disk database per test; no mocks anywhere.
private final class SQLiteFixture {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-test-\(UUID().uuidString).sqlite")
    }

    var path: String { url.path }

    @discardableResult
    func populate(_ statements: [String]) throws -> Self {
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            for statement in statements {
                try db.execute(sql: statement)
            }
        }
        return self
    }

    func makeAdapter(readOnly: Bool = false) throws -> SQLiteAdapter {
        try SQLiteAdapter(input: .init(name: "Test", filePath: path, readOnly: readOnly))
    }

    deinit {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path + suffix))
        }
    }
}

final class SQLiteAdapterTests: XCTestCase {
    // MARK: - Opening

    func testRejectsInvalidFilePaths() {
        XCTAssertThrowsError(try SQLiteAdapter(input: .init(name: "t", filePath: "")))
        XCTAssertThrowsError(try SQLiteAdapter(input: .init(name: "t", filePath: "   ")))
        XCTAssertThrowsError(try SQLiteAdapter(input: .init(name: "t", filePath: "abc\0def")))
    }

    func testOpenFailureIsSanitized() async throws {
        let badPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-missing-dir-\(UUID().uuidString)")
            .appendingPathComponent("db.sqlite").path
        do {
            let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: badPath, readOnly: true))
            _ = try await adapter.listObjects()
            XCTFail("opening a database in a missing directory must fail")
        } catch {
            let message = (error as? dbbbbError)?.userMessage ?? error.localizedDescription
            XCTAssertFalse(message.contains(badPath), "leaked path in: \(message)")
            XCTAssertFalse(message.contains(FileManager.default.temporaryDirectory.path),
                           "leaked path in: \(message)")
        }
    }

    func testProfile() throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter(readOnly: true)
        XCTAssertEqual(adapter.profile.engine, .sqlite)
        XCTAssertEqual(adapter.profile.database, fixture.url.lastPathComponent)
        XCTAssertTrue(adapter.profile.readOnly)
        XCTAssertEqual(adapter.profile.name, "Test")
    }

    // MARK: - Object tree & preview

    func testObjectTree() async throws {
        let fixture = try SQLiteFixture().populate([
            "CREATE TABLE alpha (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)",
            "CREATE TABLE beta (x REAL)",
            "CREATE VIEW alpha_view AS SELECT name FROM alpha",
        ])
        let adapter = try fixture.makeAdapter()
        let objects = try await adapter.listObjects()

        let root = objects[0]
        XCTAssertEqual(root.kind, .schema)
        XCTAssertEqual(root.name, "main")
        XCTAssertNil(root.parentID)

        let children = objects.dropFirst()
        // sqlite_sequence (from AUTOINCREMENT) must be excluded.
        XCTAssertEqual(children.map(\.name), ["alpha", "alpha_view", "beta"])
        XCTAssertEqual(children.map(\.kind), [.table, .view, .table])
        XCTAssertTrue(children.allSatisfy { $0.parentID == root.id })
        XCTAssertTrue(objects.allSatisfy { $0.id.hasPrefix("sqlite:") })
        XCTAssertEqual(Set(objects.map(\.id)).count, objects.count)
    }

    func testPreviewQuotesIdentifiersAndLimits() async throws {
        let fixture = try SQLiteFixture().populate([
            "CREATE TABLE \"we\"\"ird name\" (x INTEGER)",
            """
            INSERT INTO "we""ird name"
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 105)
            SELECT x FROM c
            """,
        ])
        let adapter = try fixture.makeAdapter()
        let table = try await adapter.listObjects().first { $0.kind == .table }
        let tableObject = try XCTUnwrap(table)
        XCTAssertEqual(tableObject.name, "we\"ird name")

        guard case .rows(_, let rows, let meta) = try await adapter.previewObject(tableObject) else {
            return XCTFail("expected rows")
        }
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(meta.count, 100)
    }

    func testPreviewRejectsNonTableObjects() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        let schema = DatabaseObject(id: "sqlite:test", parentID: nil, name: "main", kind: .schema)
        do {
            _ = try await adapter.previewObject(schema)
            XCTFail("schema nodes cannot be previewed")
        } catch let error as AdapterError {
            guard case .notFound = error else { return XCTFail("expected notFound, got \(error)") }
        }
    }

    // MARK: - Value mapping

    func testValueMapping() async throws {
        let fixture = try SQLiteFixture().populate([
            "CREATE TABLE vals (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)",
            "INSERT INTO vals VALUES (42, 1.5, 'hello', x'0102FF', NULL)",
        ])
        let adapter = try fixture.makeAdapter()
        let result = try await adapter.execute(.sql(
            "SELECT i, r, t, b, n, 9223372036854775807 AS big, -9223372036854775808 AS small, 9e999 AS inf, -9e999 AS ninf FROM vals"
        ), options: ExecuteOptions())

        guard case .rows(let columns, let rows, _) = result else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row[0], .number(42))
        XCTAssertEqual(row[1], .number(1.5))
        XCTAssertEqual(row[2], .string("hello"))
        XCTAssertEqual(row[3], .binary(Data([0x01, 0x02, 0xFF])))
        XCTAssertEqual(row[4], .null)
        // Precision past 2^53 crosses as a string.
        XCTAssertEqual(row[5], .string("9223372036854775807"))
        XCTAssertEqual(row[6], .string("-9223372036854775808"))
        // Non-finite doubles cross as strings.
        XCTAssertEqual(row[7], .string("Infinity"))
        XCTAssertEqual(row[8], .string("-Infinity"))

        XCTAssertEqual(columns[0].numeric, true)
        XCTAssertEqual(columns[0].typeName, "INTEGER")
        XCTAssertEqual(columns[2].numeric, false)
        XCTAssertEqual(columns[5].numeric, true)
    }

    func testSafeIntegerBoundaryStaysNumeric() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        let result = try await adapter.execute(.sql(
            "SELECT 9007199254740991 AS hi, -9007199254740991 AS lo, 9007199254740992 AS over"
        ), options: ExecuteOptions())
        guard case .rows(_, let rows, _) = result else { return XCTFail("expected rows") }
        XCTAssertEqual(rows[0][0], .number(9_007_199_254_740_991))
        XCTAssertEqual(rows[0][1], .number(-9_007_199_254_740_991))
        XCTAssertEqual(rows[0][2], .string("9007199254740992"))
    }

    func testDuplicateColumnNamesAreDeduped() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        let result = try await adapter.execute(.sql("SELECT 1 AS x, 2 AS x, 3 AS x"), options: ExecuteOptions())
        guard case .rows(let columns, _, _) = result else { return XCTFail("expected rows") }
        XCTAssertEqual(columns.map(\.name), ["x", "x:1", "x:2"])
    }

    // MARK: - Budgets

    func testRowBudgetTruncates() async throws {
        let fixture = try SQLiteFixture().populate([
            "CREATE TABLE nums (x INTEGER)",
            """
            INSERT INTO nums
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 600)
            SELECT x FROM c
            """,
        ])
        let adapter = try fixture.makeAdapter()

        guard case .rows(_, let rows, let meta) = try await adapter.execute(
            .sql("SELECT x FROM nums"), options: ExecuteOptions()
        ) else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.count, 500)
        XCTAssertEqual(meta.count, 500)
        XCTAssertTrue(meta.truncated)

        guard case .rows(_, let smallRows, let smallMeta) = try await adapter.execute(
            .sql("SELECT x FROM nums"), options: ExecuteOptions(maxRows: 10)
        ) else { return XCTFail("expected rows") }
        XCTAssertEqual(smallRows.count, 10)
        XCTAssertTrue(smallMeta.truncated)
    }

    func testByteBudgetTruncates() async throws {
        let fixture = try SQLiteFixture().populate([
            "CREATE TABLE big (payload TEXT)",
            """
            INSERT INTO big
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 100)
            SELECT replace(hex(zeroblob(500)), '00', 'xx') FROM c
            """,
        ])
        let adapter = try fixture.makeAdapter()
        guard case .rows(_, let rows, let meta) = try await adapter.execute(
            .sql("SELECT payload FROM big"),
            options: ExecuteOptions(maxRows: 500, maxBytes: 10_000)
        ) else { return XCTFail("expected rows") }
        XCTAssertTrue(meta.truncated)
        XCTAssertLessThan(rows.count, 100)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertEqual(meta.count, rows.count)
    }

    func testSingleValueOverEightMiBIsTruncatedWithMarker() async throws {
        let nineMiB = 9 * 1024 * 1024
        let fixture = SQLiteFixture()
        let queue = try DatabaseQueue(path: fixture.path)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE huge (b BLOB, s TEXT)")
            try db.execute(
                sql: "INSERT INTO huge VALUES (zeroblob(?), replace(hex(zeroblob(? / 2)), '00', 'yy'))",
                arguments: [nineMiB, nineMiB]
            )
        }
        let adapter = try fixture.makeAdapter()
        guard case .rows(_, let rows, _) = try await adapter.execute(
            .sql("SELECT b, s FROM huge"),
            options: ExecuteOptions(maxRows: 10, maxBytes: 32 * 1024 * 1024)
        ) else { return XCTFail("expected rows") }

        guard case .binary(let blob) = rows[0][0], case .string(let text) = rows[0][1] else {
            return XCTFail("expected truncated binary and string")
        }
        let markerSuffix = Data("…[dbbbb truncated \(nineMiB - 8 * 1024 * 1024) bytes]".utf8)
        XCTAssertTrue(blob.count > 8 * 1024 * 1024)
        XCTAssertTrue(blob.suffix(markerSuffix.count) == markerSuffix,
                      "binary value must end with the truncation marker")
        XCTAssertTrue(text.hasSuffix("…[dbbbb truncated \(nineMiB - 8 * 1024 * 1024) bytes]"))
        XCTAssertGreaterThan(text.utf8.count, 8 * 1024 * 1024)
    }

    // MARK: - Read-only sessions

    func testReadOnlySessionRejectsWrites() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter(readOnly: true)

        // Reads work.
        guard case .rows = try await adapter.execute(.sql("SELECT count(*) FROM t"), options: ExecuteOptions())
        else { return XCTFail("expected rows") }

        for sql in [
            "INSERT INTO t VALUES (1)",
            "UPDATE t SET x = 1",
            "DELETE FROM t",
            "PRAGMA user_version = 1",
            "DROP TABLE t",
            "ATTACH DATABASE 'other.sqlite' AS other",
        ] {
            await XCTAssertAsyncThrowsReadOnly(try await adapter.execute(.sql(sql), options: ExecuteOptions()), sql)
        }

        // The classifier's defense held; confirm through a writable session
        // that nothing slipped through.
        let writable = try fixture.makeAdapter()
        guard case .rows(_, let rows, _) = try await writable.execute(
            .sql("SELECT count(*) AS c FROM t"), options: ExecuteOptions()
        ), case .number(let count) = rows[0][0] else { return XCTFail("expected rows") }
        XCTAssertEqual(count, 0)
    }

    private func XCTAssertAsyncThrowsReadOnly(
        _ expression: @autoclosure () async throws -> QueryResult,
        _ sql: String
    ) async {
        do {
            _ = try await expression()
            XCTFail("read-only session accepted: \(sql)")
        } catch {
            XCTAssertFalse((error as? dbbbbError)?.userMessage.isEmpty ?? true)
        }
    }

    func testReadOnlySessionOpensFileReadOnly() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter(readOnly: true)
        XCTAssertTrue(adapter.profile.readOnly)
        let objects = try await adapter.listObjects()
        XCTAssertEqual(objects.dropFirst().map(\.name), ["t"])
    }

    func testWritableSessionStillRejectsMultipleStatements() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        do {
            _ = try await adapter.execute(.sql("SELECT 1; SELECT 2"), options: ExecuteOptions())
            XCTFail("multi-statement input must be rejected")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.contains("one SQL statement"))
        }
    }

    // MARK: - Errors

    func testQueryErrorIsSanitized() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        do {
            _ = try await adapter.execute(.sql("SELECT * FROM missing_table"), options: ExecuteOptions())
            XCTFail("query against a missing table must fail")
        } catch let error as SQLiteAdapterError {
            XCTAssertTrue(error.userMessage.hasPrefix("SQLite query failed:"))
            XCTAssertFalse(error.userMessage.contains(fixture.path), "leaked path in: \(error.userMessage)")
            XCTAssertLessThanOrEqual(error.userMessage.count, 620)
        }
    }

    func testEngineMismatch() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        do {
            _ = try await adapter.execute(.mongoFind(collection: "t", filter: "{}"), options: ExecuteOptions())
            XCTFail("mongo commands must be rejected")
        } catch let error as AdapterError {
            XCTAssertEqual(error, .engineMismatch)
        }
    }

    // MARK: - Cancellation

    func testCancelInterruptsRunningQuery() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        // A single aggregate over a 100M-row recursion: no rows are emitted
        // until the recursion completes, so only a real interrupt stops it.
        let sql = """
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 100000000)
            SELECT sum(x) FROM c
            """

        let task = Task { try await adapter.execute(.sql(sql), options: ExecuteOptions()) }
        try await Task.sleep(for: .milliseconds(300))
        try await adapter.cancel(requestID: UUID())

        switch await task.result {
        case .success:
            XCTFail("the query should have been interrupted")
        case .failure(let error):
            let message = (error as? dbbbbError)?.userMessage ?? error.localizedDescription
            XCTAssertTrue(message.contains("interrupt"), "unexpected error: \(message)")
        }
    }

    // MARK: - Close

    func testCloseIsIdempotent() async throws {
        let fixture = try SQLiteFixture().populate(["CREATE TABLE t (x INTEGER)"])
        let adapter = try fixture.makeAdapter()
        await adapter.close()
        await adapter.close()

        do {
            _ = try await adapter.listObjects()
            XCTFail("closed sessions must fail")
        } catch let error as AdapterError {
            XCTAssertEqual(error, .sessionClosed)
        }
        do {
            try await adapter.cancel(requestID: UUID())
            XCTFail("closed sessions must fail")
        } catch let error as AdapterError {
            XCTAssertEqual(error, .sessionClosed)
        }
    }
}
