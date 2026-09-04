import XCTest
import Foundation
import dbbbbCore
@testable import dbbbbKit

/// Integration tests against a real MySQL server. Gated on
/// `DBBBB_TEST_MYSQL_URL`, e.g. `mysql://root:secret@127.0.0.1:3306/test`.
/// Every test skips when the variable is unset.
final class MySQLAdapterIntegrationTests: XCTestCase {
    private func makeInput(readOnly: Bool = false) throws -> ConnectionInput.MySQLInput {
        guard let urlString = ProcessInfo.processInfo.environment["DBBBB_TEST_MYSQL_URL"],
              let url = URL(string: urlString),
              let host = url.host,
              let database = url.path.split(separator: "/").first.map(String.init),
              !database.isEmpty
        else {
            throw XCTSkip("DBBBB_TEST_MYSQL_URL is not set")
        }
        var sslMode: SSLMode = .disable
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let mode = components.queryItems?.first(where: { $0.name == "sslmode" })?.value {
            switch mode {
            case "require": sslMode = .require
            case "verify-full": sslMode = .verifyFull
            default: sslMode = .disable
            }
        }
        return ConnectionInput.MySQLInput(
            name: "integration",
            host: host,
            port: url.port ?? 3306,
            username: url.user ?? "root",
            password: url.password ?? "",
            database: database,
            sslMode: sslMode,
            readOnly: readOnly
        )
    }

    private func makeAdapter(readOnly: Bool = false) throws -> MySQLAdapter {
        let adapter = try MySQLAdapter(input: makeInput(readOnly: readOnly))
        addTeardownBlock {
            await adapter.close()
        }
        return adapter
    }

    func testSelectOne() async throws {
        let adapter = try makeAdapter()
        let result = try await adapter.execute(.sql("SELECT 1 AS one, 'x' AS label"), options: ExecuteOptions())
        guard case .rows(let columns, let rows, let meta) = result else {
            return XCTFail("expected rows result")
        }
        XCTAssertEqual(columns.map(\.name), ["one", "label"])
        XCTAssertEqual(rows, [[.number(1), .string("x")]])
        XCTAssertEqual(meta.count, 1)
        XCTAssertFalse(meta.truncated)
    }

    func testFidelityValues() async throws {
        let adapter = try makeAdapter()
        let result = try await adapter.execute(
            .sql("SELECT 9223372036854775807 AS b, CAST(0.1 AS DECIMAL(10,2)) AS d, DATE '2024-01-02' AS dt"),
            options: ExecuteOptions()
        )
        guard case .rows(_, let rows, _) = result, rows.count == 1 else {
            return XCTFail("expected one row")
        }
        XCTAssertEqual(rows[0][0], .string("9223372036854775807"))
        XCTAssertEqual(rows[0][1], .string("0.10"))
        XCTAssertEqual(rows[0][2], .string("2024-01-02"))
    }

    func testListObjectsContainsDatabaseNode() async throws {
        let adapter = try makeAdapter()
        let objects = try await adapter.listObjects()
        XCTAssertEqual(objects.first?.kind, .database)
        XCTAssertEqual(objects.first?.name, adapter.profile.database)
        XCTAssertTrue(objects.dropFirst().allSatisfy { $0.parentID == objects.first?.id })
    }

    func testPreviewObjectRespectsLimit() async throws {
        let adapter = try makeAdapter()
        let objects = try await adapter.listObjects()
        guard let table = objects.first(where: { $0.kind == .table || $0.kind == .view }) else {
            throw XCTSkip("no tables or views in the test database")
        }
        let result = try await adapter.previewObject(table)
        guard case .rows(_, let rows, let meta) = result else {
            return XCTFail("expected rows result")
        }
        XCTAssertLessThanOrEqual(rows.count, 100)
        XCTAssertEqual(meta.count, rows.count)
    }

    func testCancelInterruptsSleep() async throws {
        let adapter = try makeAdapter()
        let requestID = UUID()
        async let outcome = adapter.execute(.sql("SELECT SLEEP(30)"), options: ExecuteOptions(requestID: requestID, timeout: .seconds(60)))
        try await Task.sleep(for: .milliseconds(500))
        try await adapter.cancel(requestID: requestID)
        do {
            _ = try await outcome
            XCTFail("cancelled query should not succeed")
        } catch let error as MySQLAdapterError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testTimeoutInterruptsSleep() async throws {
        let adapter = try makeAdapter()
        do {
            _ = try await adapter.execute(
                .sql("SELECT SLEEP(30)"),
                options: ExecuteOptions(timeout: .milliseconds(500))
            )
            XCTFail("timed-out query should not succeed")
        } catch let error as MySQLAdapterError {
            XCTAssertEqual(error, .timedOut)
        }
    }

    /// sslMode=require must never silently degrade to plaintext: a TLS-capable
    /// server negotiates real encryption (proven via Ssl_cipher before the
    /// session serves queries); a server without SSL is refused fail-closed.
    func testRequireTLSNeverSilentlyDegradesToPlaintext() async throws {
        var input = try makeInput()
        input.sslMode = .require
        let adapter = try MySQLAdapter(input: input)
        addTeardownBlock {
            await adapter.close()
        }
        do {
            _ = try await adapter.execute(.sql("SELECT 1"), options: ExecuteOptions())
        } catch let error as MySQLAdapterError {
            XCTAssertEqual(error, .tlsRequired)
        }
    }

    /// A large result set stops accumulating at maxRows + 1 rows; the rest of
    /// the packets are drained and dropped.
    func testLargeResultSetStaysWithinRowBudget() async throws {
        let adapter = try makeAdapter()
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_budget"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_budget (id INT PRIMARY KEY AUTO_INCREMENT, note VARCHAR(20))
            """), options: ExecuteOptions())
        addTeardownBlock {
            _ = try? await adapter.execute(
                .sql("DROP TABLE IF EXISTS dbbbb_it_budget"), options: ExecuteOptions())
        }
        _ = try await adapter.execute(.sql("""
            INSERT INTO dbbbb_it_budget (note)
            SELECT 'x' FROM information_schema.COLUMNS c1
            CROSS JOIN information_schema.COLUMNS c2
            LIMIT 5000
            """), options: ExecuteOptions(timeout: .seconds(30)))

        let result = try await adapter.execute(
            .sql("SELECT id, note FROM dbbbb_it_budget"),
            options: ExecuteOptions(timeout: .seconds(30), maxRows: 50))
        guard case .rows(_, let rows, let meta) = result else {
            return XCTFail("expected rows result")
        }
        XCTAssertEqual(rows.count, 50)
        XCTAssertTrue(meta.truncated)
    }

    func testReadOnlyRejectsWrites() async throws {
        let adapter = try makeAdapter(readOnly: true)
        await XCTAssertReadOnlyError("CREATE TABLE dbbbb_ro_test (a INT)", adapter)
        await XCTAssertReadOnlyError("SELECT GET_LOCK('x', 1)", adapter)
        // Reads still work on a read-only session (server guardrail active).
        _ = try await adapter.execute(.sql("SELECT 1"), options: ExecuteOptions())
    }

    private func XCTAssertReadOnlyError(
        _ sql: String,
        _ adapter: MySQLAdapter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await adapter.execute(.sql(sql), options: ExecuteOptions())
            XCTFail("expected read-only rejection for \(sql)", file: file, line: line)
        } catch let error as MySQLAdapterError {
            switch error {
            case .statementNotReadOnly, .forbiddenToken, .unclassifiableSQL, .multipleStatements:
                break
            default:
                XCTFail("unexpected error \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Editing

    private func rows(_ result: QueryResult) throws -> (columns: [ColumnMeta], rows: [[DisplayValue]]) {
        guard case .rows(let columns, let rows, _) = result else {
            throw MySQLAdapterError.failure("expected rows result")
        }
        return (columns, rows)
    }

    private func originalRecord(columns: [ColumnMeta], row: [DisplayValue]) -> [String: DisplayValue] {
        Dictionary(zip(columns, row).map { ($0.0.name, $0.1) }) { first, _ in first }
    }

    private func editingTable(
        _ adapter: MySQLAdapter, name: String
    ) async throws -> DatabaseObject {
        let objects = try await adapter.listObjects()
        guard let table = objects.first(where: { $0.kind == .table && $0.name == name }) else {
            throw MySQLAdapterError.failure("scratch table \(name) missing from object tree")
        }
        return table
    }

    func testApplyDataChangeUpdateConflictAndDelete() async throws {
        let adapter = try makeAdapter()
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_edit"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_edit (
                id INT PRIMARY KEY,
                note VARCHAR(100),
                amount DECIMAL(10,2)
            )
            """), options: ExecuteOptions())
        addTeardownBlock {
            _ = try? await adapter.execute(
                .sql("DROP TABLE IF EXISTS dbbbb_it_edit"), options: ExecuteOptions())
        }
        _ = try await adapter.execute(.sql("""
            INSERT INTO dbbbb_it_edit (id, note, amount)
            VALUES (1, 'before', 10.50), (2, 'sibling', 20.00)
            """), options: ExecuteOptions())

        let table = try await editingTable(adapter, name: "dbbbb_it_edit")
        let (columns, previewRows) = try rows(try await adapter.previewObject(table))
        guard let row = previewRows.first(where: { $0[0] == .number(1) }) else {
            return XCTFail("inserted row missing from preview")
        }
        let original = originalRecord(columns: columns, row: row)

        // Update one column through the editing capability (NULL-less decimal
        // binds back from its display string).
        let updated = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["note": .string("after"), "amount": .string("11.25")])))
        XCTAssertEqual(updated.meta.count, 1)

        // Replaying the stale baseline is an optimistic-concurrency conflict.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: original,
                operation: .update(changed: ["note": .string("stale")])))
            XCTFail("stale baseline must conflict")
        } catch let error as MySQLAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        // The sibling row is untouched.
        let (_, checkRows) = try rows(try await adapter.execute(.sql(
            "SELECT note FROM dbbbb_it_edit WHERE id = 2"), options: ExecuteOptions()))
        XCTAssertEqual(checkRows.first?.first, .string("sibling"))

        // Delete with the current baseline, then replay it for the conflict.
        let (freshColumns, freshRows) = try rows(try await adapter.previewObject(table))
        guard let freshRow = freshRows.first(where: { $0[0] == .number(1) }) else {
            return XCTFail("updated row missing from preview")
        }
        let freshOriginal = originalRecord(columns: freshColumns, row: freshRow)
        _ = try await adapter.applyDataChange(DataChange(
            object: table, original: freshOriginal, operation: .delete))
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table, original: freshOriginal, operation: .delete))
            XCTFail("deleting a deleted row must conflict")
        } catch let error as MySQLAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        let (_, remainingRows) = try rows(try await adapter.execute(.sql(
            "SELECT id FROM dbbbb_it_edit ORDER BY id"), options: ExecuteOptions()))
        XCTAssertEqual(remainingRows.map { $0[0] }, [.number(2)])
    }

    /// Round-trip proof: precision-sensitive displayed values (BIGINT beyond
    /// 2^53, DECIMAL, DATETIME, BLOB, TINYINT(1) bool, NULL) must bind back
    /// losslessly, or the optimistic match would misreport a conflict.
    func testApplyDataChangeRoundTripsPrecisionSensitiveValues() async throws {
        let adapter = try makeAdapter()
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_edit_types"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_edit_types (
                id INT PRIMARY KEY,
                big BIGINT,
                scaled DECIMAL(12,4),
                moment DATETIME(6),
                payload VARBINARY(100),
                flag TINYINT(1),
                note VARCHAR(100)
            )
            """), options: ExecuteOptions())
        addTeardownBlock {
            _ = try? await adapter.execute(
                .sql("DROP TABLE IF EXISTS dbbbb_it_edit_types"), options: ExecuteOptions())
        }
        _ = try await adapter.execute(.sql("""
            INSERT INTO dbbbb_it_edit_types
            VALUES (1, 9007199254740993, 1.10, '2024-02-29 01:02:03.456789',
                    X'DEADBEEF', 1, NULL)
            """), options: ExecuteOptions())

        let table = try await editingTable(adapter, name: "dbbbb_it_edit_types")
        let (columns, previewRows) = try rows(try await adapter.previewObject(table))
        XCTAssertEqual(previewRows.count, 1)
        let original = originalRecord(columns: columns, row: previewRows[0])
        XCTAssertEqual(original["big"], .string("9007199254740993"))
        XCTAssertEqual(original["scaled"], .string("1.1000"))
        XCTAssertEqual(original["moment"], .string("2024-02-29 01:02:03.456789"))
        XCTAssertEqual(original["payload"], .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertEqual(original["flag"], .bool(true))
        XCTAssertEqual(original["note"], .null)

        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["note": .string("edited"), "flag": .bool(false)])))

        let (_, resultRows) = try rows(try await adapter.execute(.sql(
            "SELECT big, scaled, moment, payload, flag, note FROM dbbbb_it_edit_types WHERE id = 1"),
            options: ExecuteOptions()))
        XCTAssertEqual(resultRows.count, 1)
        let updated = originalRecord(
            columns: [ColumnMeta(name: "big", typeName: "", numeric: true),
                      ColumnMeta(name: "scaled", typeName: "", numeric: true),
                      ColumnMeta(name: "moment", typeName: "", numeric: false),
                      ColumnMeta(name: "payload", typeName: "", numeric: false),
                      ColumnMeta(name: "flag", typeName: "", numeric: true),
                      ColumnMeta(name: "note", typeName: "", numeric: false)],
            row: resultRows[0])
        XCTAssertEqual(updated["big"], original["big"])
        XCTAssertEqual(updated["scaled"], original["scaled"])
        XCTAssertEqual(updated["moment"], original["moment"])
        XCTAssertEqual(updated["payload"], original["payload"])
        XCTAssertEqual(updated["flag"], .bool(false))
        XCTAssertEqual(updated["note"], .string("edited"))
    }

    /// Byte-level lock proof against real collation semantics: under the
    /// default `utf8mb4_0900_ai_ci` a concurrent case-only rewrite is
    /// invisible to native `<=>`, so it must surface as an
    /// optimistic-concurrency conflict; the untouched row still edits cleanly.
    func testApplyDataChangeDetectsCaseOnlyConcurrentRewrite() async throws {
        let adapter = try makeAdapter()
        let external = try makeAdapter()
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_edit_ci"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_edit_ci (
                id INT PRIMARY KEY,
                code VARCHAR(100),
                note VARCHAR(100)
            )
            """), options: ExecuteOptions())
        addTeardownBlock {
            _ = try? await adapter.execute(
                .sql("DROP TABLE IF EXISTS dbbbb_it_edit_ci"), options: ExecuteOptions())
        }
        _ = try await adapter.execute(.sql(
            "INSERT INTO dbbbb_it_edit_ci VALUES (1, 'ABC', 'keep')"),
            options: ExecuteOptions())

        let table = try await editingTable(adapter, name: "dbbbb_it_edit_ci")
        let (columns, previewRows) = try rows(try await adapter.previewObject(table))
        guard let row = previewRows.first(where: { $0[0] == .number(1) }) else {
            return XCTFail("inserted row missing from preview")
        }
        let original = originalRecord(columns: columns, row: row)
        XCTAssertEqual(original["code"], .string("ABC"))

        // Control: the untouched row edits cleanly under the byte-level lock.
        _ = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["note": .string("edited")])))

        // A concurrent case-only rewrite (equal under ai_ci) must conflict.
        let (staleColumns, staleRows) = try rows(try await adapter.previewObject(table))
        let stale = originalRecord(columns: staleColumns, row: staleRows[0])
        _ = try await external.execute(.sql(
            "UPDATE dbbbb_it_edit_ci SET code = 'abc' WHERE id = 1"),
            options: ExecuteOptions())
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: stale,
                operation: .update(changed: ["note": .string("touched")])))
            XCTFail("case-only rewrite under utf8mb4_0900_ai_ci must conflict")
        } catch let error as MySQLAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }

        // Stale deletes conflict too, and the externally rewritten row survives.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table, original: stale, operation: .delete))
            XCTFail("stale delete under utf8mb4_0900_ai_ci must conflict")
        } catch let error as MySQLAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"),
                          error.userMessage)
        }
        let (_, remaining) = try rows(try await adapter.execute(.sql(
            "SELECT code FROM dbbbb_it_edit_ci WHERE id = 1"), options: ExecuteOptions()))
        XCTAssertEqual(remaining.first?.first, .string("abc"))
    }

    func testApplyDataChangeRejectsReadOnlyAndUnknownTargets() async throws {
        let readOnlyAdapter = try makeAdapter(readOnly: true)
        let fakeTable = DatabaseObject(
            id: "mysql:unknown", parentID: nil, name: "t", kind: .table)
        do {
            _ = try await readOnlyAdapter.applyDataChange(DataChange(
                object: fakeTable,
                original: ["id": .number(1)],
                operation: .delete))
            XCTFail("read-only session must refuse row changes")
        } catch let error as MySQLAdapterError {
            XCTAssertTrue(error.userMessage.contains("read-only"), error.userMessage)
        }

        // A writable adapter still refuses objects that are not introspected tables.
        let adapter = try makeAdapter()
        let viewObject = DatabaseObject(
            id: "mysql:also-unknown", parentID: nil, name: "v", kind: .view)
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: viewObject,
                original: ["id": .number(1)],
                operation: .delete))
            XCTFail("unknown targets must be refused")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    // MARK: - Import

    private func makeImportFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-mysql-import-\(UUID().uuidString).csv")
        try Data(contents.utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testImportCSVIntoScratchTable() async throws {
        let adapter = try makeAdapter()
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_import"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_import (
                id INT PRIMARY KEY,
                name VARCHAR(100) NOT NULL,
                amount DECIMAL(10,2),
                created DATE
            )
            """), options: ExecuteOptions())
        addTeardownBlock {
            _ = try? await adapter.execute(
                .sql("DROP TABLE IF EXISTS dbbbb_it_import"), options: ExecuteOptions())
        }
        let objects = try await adapter.listObjects()
        guard let table = objects.first(where: { $0.kind == .table && $0.name == "dbbbb_it_import" })
        else { return XCTFail("scratch table missing from object tree") }

        let csv = try makeImportFile(
            "id,name,amount,created\r\n1,Ada,19.99,2024-01-01\r\n2,\"Bo,b\",7.5,2024-02-29\r\n")
        let summary = try await adapter.importData(ImportRequest(
            target: table, format: .csv, fileURL: csv, hasHeader: true))
        XCTAssertEqual(summary, ImportSummary(processed: 2, inserted: 2, failed: 0))

        // The server coerced the string binds into the column types.
        let result = try await adapter.execute(
            .sql("SELECT id, name FROM dbbbb_it_import ORDER BY id"),
            options: ExecuteOptions())
        guard case .rows(_, let rows, _) = result else {
            return XCTFail("expected rows result")
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][1], .string("Ada"))
        XCTAssertEqual(rows[1][1], .string("Bo,b"))

        // A failing batch rolls the whole single-transaction import back.
        let bad = try makeImportFile("id,name\n3,Ok\nnot-an-int,Bad\n")
        do {
            _ = try await adapter.importData(ImportRequest(
                target: table, format: .csv, fileURL: bad, hasHeader: true))
            XCTFail("expected the bad batch to abort the import")
        } catch let error as ImportError {
            guard case .insertFailed = error else {
                return XCTFail("expected insertFailed, got \(error)")
            }
        }
        let after = try await adapter.execute(
            .sql("SELECT id FROM dbbbb_it_import ORDER BY id"), options: ExecuteOptions())
        guard case .rows(_, let countRows, _) = after else {
            return XCTFail("expected rows result")
        }
        XCTAssertEqual(countRows, [[.number(1)], [.number(2)]])
    }

    func testImportRefusedForReadOnlySessions() async throws {
        let adapter = try makeAdapter(readOnly: true)
        let csv = try makeImportFile("id,name\n1,Ada\n")
        let table = DatabaseObject(id: "mysql:ignored", parentID: nil, name: "t", kind: .table)
        do {
            _ = try await adapter.importData(ImportRequest(
                target: table, format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected unsupported")
        } catch let error as ImportError {
            XCTAssertEqual(
                error,
                .unsupported("MySQL import is disabled for read-only connections."))
        }
    }
}
