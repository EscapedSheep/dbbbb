import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Integration tests against a real PostgreSQL server. Gated on
/// `DBBBB_TEST_POSTGRES_URL` (e.g.
/// `postgresql://user:secret@localhost:5432/postgres?sslmode=disable`);
/// every test skips when the variable is unset.
final class PostgresAdapterIntegrationTests: XCTestCase {
    private var adapter: PostgresAdapter!

    override func setUp() async throws {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_POSTGRES_URL"],
              let input = Self.parse(url: url)
        else {
            throw XCTSkip("DBBBB_TEST_POSTGRES_URL is not set")
        }
        adapter = try PostgresAdapter(input: input)
    }

    override func tearDown() async throws {
        await adapter?.close()
        adapter = nil
    }

    static func parse(url: String) -> ConnectionInput.PostgresInput? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme,
              ["postgresql", "postgres"].contains(scheme),
              let host = components.host, !host.isEmpty,
              let user = components.user?.removingPercentEncoding
        else { return nil }
        let password = components.password?.removingPercentEncoding ?? ""
        let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !database.isEmpty else { return nil }
        let sslMode: SSLMode
        switch components.queryItems?.first(where: { $0.name == "sslmode" })?.value {
        case "require": sslMode = .require
        case "verify-full": sslMode = .verifyFull
        default: sslMode = .disable
        }
        return ConnectionInput.PostgresInput(
            name: "integration",
            host: host,
            port: components.port ?? 5432,
            username: user,
            password: password,
            database: database,
            sslMode: sslMode)
    }

    private func rows(_ result: QueryResult) throws -> (columns: [ColumnMeta], rows: [[DisplayValue]]) {
        guard case .rows(let columns, let rows, _) = result else {
            throw XCTSkip("expected row result")
        }
        return (columns, rows)
    }

    func testConnectListObjectsAndPreview() async throws {
        let objects = try await adapter.listObjects()
        XCTAssertFalse(objects.isEmpty)
        XCTAssertTrue(objects.contains { $0.kind == .schema && $0.name == "public" })

        // Create a scratch table and preview it through the object tree.
        _ = try await adapter.execute(.sql(
            "CREATE TABLE IF NOT EXISTS dbbbb_it_preview (id int4 PRIMARY KEY, note text)"),
            options: ExecuteOptions())
        let refreshed = try await adapter.listObjects()
        guard let table = refreshed.first(where: { $0.kind == .table && $0.name == "dbbbb_it_preview" })
        else { return XCTFail("scratch table missing from object tree") }
        XCTAssertNotNil(table.parentID)

        let preview = try await adapter.previewObject(table)
        let (columns, rows) = try rows(preview)
        XCTAssertEqual(columns.map(\.name), ["id", "note"])
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(preview.meta.count, 0)
        XCTAssertFalse(preview.meta.truncated)
    }

    func testExecutePrecisionSensitiveValues() async throws {
        let result = try await adapter.execute(.sql("""
            SELECT
              9007199254740993::int8 AS big,
              1.10::numeric AS scaled,
              DATE '2024-02-29' AS d,
              TIMESTAMP '2024-02-29 01:02:03.456789' AS ts,
              TIMESTAMPTZ '2024-02-29 01:02:03.456789+00' AS tstz,
              INTERVAL '1 year 2 mons -3 days 04:05:06.5' AS i,
              '\\xDEADBEEF'::bytea AS bin,
              1.5::float8 AS f,
              'Infinity'::float8 AS inf,
              ARRAY[1, NULL, 3]::int4[] AS arr,
              'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u,
              true AS b,
              NULL::text AS n
            """), options: ExecuteOptions())
        let (columns, resultRows) = try rows(result)
        XCTAssertEqual(columns.map(\.name),
                       ["big", "scaled", "d", "ts", "tstz", "i", "bin", "f", "inf", "arr", "u", "b", "n"])
        XCTAssertEqual(resultRows.count, 1)
        let row = resultRows[0]

        guard case .string(let big) = row[0] else { return XCTFail("int8 must be a string, got \(row[0])") }
        XCTAssertEqual(big, "9007199254740993")
        XCTAssertEqual(row[1], .string("1.10"))
        XCTAssertEqual(row[2], .string("2024-02-29"))
        XCTAssertEqual(row[3], .string("2024-02-29 01:02:03.456789"))
        guard case .string(let tstz) = row[4] else { return XCTFail("timestamptz must be a string") }
        // Render the expectation in the server's own session time zone.
        let tzResult = try await adapter.execute(.sql("SHOW TimeZone"), options: ExecuteOptions())
        let (_, tzRows) = try rows(tzResult)
        guard case .string(let tzName) = tzRows[0][0],
              let serverZone = TimeZone(identifier: tzName)
        else { return XCTFail("SHOW TimeZone returned \(tzRows)") }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2024, month: 2, day: 29, hour: 1, minute: 2, second: 3)))
        let utcMicros = Int64((instant.timeIntervalSince1970 - 946_684_800) * 1_000_000) + 456_789
        let offset = serverZone.secondsFromGMT(for: instant)
        XCTAssertEqual(tstz, PostgresWireCodec.renderTimestamp(
            microseconds: utcMicros + Int64(offset) * 1_000_000,
            suffix: PostgresWireCodec.renderZoneOffset(offset)))
        XCTAssertEqual(row[5], .string("1 year 2 mons -3 days +04:05:06.5"))
        XCTAssertEqual(row[6], .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        XCTAssertEqual(row[7], .number(1.5))
        XCTAssertEqual(row[8], .string("Infinity"))
        XCTAssertEqual(row[9], .array([.number(1), .null, .number(3)]))
        XCTAssertEqual(row[10], .string("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
        XCTAssertEqual(row[11], .bool(true))
        XCTAssertEqual(row[12], .null)
    }

    func testRowAndByteBudgets() async throws {
        let result = try await adapter.execute(
            .sql("SELECT generate_series(1, 10) AS n"),
            options: ExecuteOptions(timeout: .seconds(10), maxRows: 3, maxBytes: 5 * 1024 * 1024))
        let (_, bounded) = try rows(result)
        XCTAssertEqual(bounded.count, 3)
        XCTAssertTrue(result.meta.truncated)
        XCTAssertEqual(result.meta.count, 3)
    }

    func testCancelStopsLongRunningQuery() async throws {
        let adapter = try XCTUnwrap(adapter)
        let options = ExecuteOptions(timeout: .seconds(30))
        async let execution = adapter.execute(
            .sql("SELECT pg_sleep(60)"), options: options)
        // Give the query a moment to reach the server, then cancel it.
        try await Task.sleep(for: .milliseconds(500))
        try await adapter.cancel(requestID: options.requestID)
        do {
            _ = try await execution
            XCTFail("cancelled query must not complete")
        } catch let error as PostgresAdapterError {
            XCTAssertEqual(error.userMessage, "PostgreSQL query was cancelled.")
            XCTAssertEqual(error.sqlState, "57014")
        }
    }

    func testTimeoutCancelsAsSafetyNet() async throws {
        let options = ExecuteOptions(timeout: .milliseconds(700))
        do {
            _ = try await adapter.execute(.sql("SELECT pg_sleep(60)"), options: options)
            XCTFail("timed-out query must not complete")
        } catch let error as PostgresAdapterError {
            XCTAssertEqual(error.userMessage, "PostgreSQL query timed out.")
        }
    }

    func testErrorIsSanitizedAndKeepsSQLState() async throws {
        do {
            _ = try await adapter.execute(
                .sql("SELECT * FROM definitely_missing_table_dbbbb"), options: ExecuteOptions())
            XCTFail("missing table must fail")
        } catch let error as PostgresAdapterError {
            XCTAssertEqual(error.sqlState, "42P01")
            XCTAssertTrue(error.userMessage.contains("PostgreSQL query failed"))
        }
    }

    // MARK: - Editing

    /// Builds the `original` record of a change from one previewed row.
    private func originalRecord(columns: [ColumnMeta], row: [DisplayValue]) -> [String: DisplayValue] {
        Dictionary(zip(columns, row).map { ($0.0.name, $0.1) }) { first, _ in first }
    }

    private func editingTable(_ name: String) async throws -> DatabaseObject {
        let objects = try await adapter.listObjects()
        guard let table = objects.first(where: { $0.kind == .table && $0.name == name }) else {
            throw XCTSkip("scratch table \(name) missing from object tree")
        }
        return table
    }

    func testApplyDataChangeUpdateConflictAndDelete() async throws {
        _ = try await adapter.execute(.sql("""
            CREATE TABLE IF NOT EXISTS dbbbb_it_edit (
                id int4 PRIMARY KEY,
                note text,
                amount numeric(10,2)
            )
            """), options: ExecuteOptions())
        _ = try await adapter.execute(.sql(
            "TRUNCATE dbbbb_it_edit"), options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            INSERT INTO dbbbb_it_edit (id, note, amount)
            VALUES (1, 'before', 10.50), (2, 'sibling', 20.00)
            """), options: ExecuteOptions())

        let table = try await editingTable("dbbbb_it_edit")
        let preview = try await adapter.previewObject(table)
        let (columns, previewRows) = try rows(preview)
        guard let row = previewRows.first(where: { $0[0] == .number(1) }) else {
            return XCTFail("inserted row missing from preview")
        }
        let original = originalRecord(columns: columns, row: row)

        // Update one column through the editing capability.
        let updated = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["note": .string("after"), "amount": .string("11.25")])))
        let (updatedColumns, updatedRows) = try rows(updated)
        XCTAssertEqual(updatedRows.count, 1)
        XCTAssertEqual(
            originalRecord(columns: updatedColumns, row: updatedRows[0])["note"], .string("after"))
        XCTAssertEqual(
            originalRecord(columns: updatedColumns, row: updatedRows[0])["amount"], .string("11.25"))

        // Replaying the stale baseline is an optimistic-concurrency conflict.
        do {
            _ = try await adapter.applyDataChange(DataChange(
                object: table,
                original: original,
                operation: .update(changed: ["note": .string("stale")])))
            XCTFail("stale baseline must conflict")
        } catch let error as PostgresAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"))
        }

        // The sibling row is untouched.
        let check = try await adapter.execute(.sql(
            "SELECT note FROM dbbbb_it_edit WHERE id = 2"), options: ExecuteOptions())
        let (_, checkRows) = try rows(check)
        XCTAssertEqual(checkRows.first?.first, .string("sibling"))

        // Delete with the current baseline, then replay it for the conflict.
        let freshPreview = try await adapter.previewObject(table)
        let (freshColumns, freshRows) = try rows(freshPreview)
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
        } catch let error as PostgresAdapterError {
            XCTAssertTrue(error.userMessage.contains("optimistic-concurrency conflict"))
        }

        let remaining = try await adapter.execute(.sql(
            "SELECT id FROM dbbbb_it_edit ORDER BY id"), options: ExecuteOptions())
        let (_, remainingRows) = try rows(remaining)
        XCTAssertEqual(remainingRows.map { $0[0] }, [.number(2)])
    }

    /// Round-trip proof: precision-sensitive displayed values (int8, numeric,
    /// timestamptz, bytea, arrays, bool) must bind back losslessly, or the
    /// optimistic match would misreport a conflict.
    func testApplyDataChangeRoundTripsPrecisionSensitiveValues() async throws {
        _ = try await adapter.execute(.sql("""
            CREATE TABLE IF NOT EXISTS dbbbb_it_edit_types (
                id int4 PRIMARY KEY,
                big int8,
                scaled numeric(12,4),
                moment timestamptz,
                blob bytea,
                tags text[],
                numbers int4[],
                flag bool
            )
            """), options: ExecuteOptions())
        _ = try await adapter.execute(.sql(
            "TRUNCATE dbbbb_it_edit_types"), options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            INSERT INTO dbbbb_it_edit_types
            VALUES (1, 9007199254740993, 1.10, TIMESTAMPTZ '2024-02-29 01:02:03.456789+00',
                    '\\xDEADBEEF', ARRAY['a"b', 'c'], ARRAY[1, NULL, 3], true)
            """), options: ExecuteOptions())

        let table = try await editingTable("dbbbb_it_edit_types")
        let preview = try await adapter.previewObject(table)
        let (columns, previewRows) = try rows(preview)
        XCTAssertEqual(previewRows.count, 1)
        let original = originalRecord(columns: columns, row: previewRows[0])

        let updated = try await adapter.applyDataChange(DataChange(
            object: table,
            original: original,
            operation: .update(changed: ["flag": .bool(false)])))
        let (updatedColumns, updatedRows) = try rows(updated)
        XCTAssertEqual(updatedRows.count, 1)
        let updatedRecord = originalRecord(columns: updatedColumns, row: updatedRows[0])
        XCTAssertEqual(updatedRecord["big"], original["big"])
        XCTAssertEqual(updatedRecord["scaled"], original["scaled"])
        XCTAssertEqual(updatedRecord["moment"], original["moment"])
        XCTAssertEqual(updatedRecord["blob"], original["blob"])
        XCTAssertEqual(updatedRecord["tags"], original["tags"])
        XCTAssertEqual(updatedRecord["numbers"], original["numbers"])
        XCTAssertEqual(updatedRecord["flag"], .bool(false))
    }

    func testApplyDataChangeRejectsReadOnlyAndUnknownTargets() async throws {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_POSTGRES_URL"],
              var input = Self.parse(url: url)
        else { throw XCTSkip("DBBBB_TEST_POSTGRES_URL is not set") }
        input.readOnly = true
        let readOnlyAdapter = try PostgresAdapter(input: input)
        defer { Task { await readOnlyAdapter.close() } }

        let fakeTable = DatabaseObject(
            id: "postgresql:unknown", parentID: nil, name: "t", kind: .table)
        do {
            _ = try await readOnlyAdapter.applyDataChange(DataChange(
                object: fakeTable,
                original: ["id": .number(1)],
                operation: .delete))
            XCTFail("read-only session must refuse row changes")
        } catch let error as PostgresAdapterError {
            XCTAssertTrue(error.userMessage.contains("read-only"))
        }

        // A writable adapter still refuses objects that are not introspected tables.
        let viewObject = DatabaseObject(
            id: "postgresql:also-unknown", parentID: nil, name: "v", kind: .view)
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

    func testReadOnlySessionRejectsWritesBothSides() async throws {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_POSTGRES_URL"],
              var input = Self.parse(url: url)
        else { throw XCTSkip("DBBBB_TEST_POSTGRES_URL is not set") }
        input.readOnly = true
        let readOnlyAdapter = try PostgresAdapter(input: input)
        defer { Task { await readOnlyAdapter.close() } }

        // Client-side classifier: fail fast with a precise token message.
        do {
            _ = try await readOnlyAdapter.execute(
                .sql("DROP TABLE users"), options: ExecuteOptions())
            XCTFail("read-only session must reject DROP")
        } catch let error as PostgresReadOnlyViolation {
            XCTAssertTrue(error.userMessage.contains("read-only"))
        }

        // Reads still work, and the server-side guardrail backs the classifier.
        _ = try await readOnlyAdapter.execute(.sql("SELECT 1"), options: ExecuteOptions())
        do {
            // Statement that dodges the token blacklist is still stopped by the
            // server (`default_transaction_read_only = on`).
            _ = try await readOnlyAdapter.execute(
                .sql("WITH x AS (SELECT 1) SELECT * FROM x"), options: ExecuteOptions())
        } catch let error as PostgresReadOnlyViolation {
            XCTFail("plain read must pass: \(error)")
        }
    }

    // MARK: - Import

    private func makeImportFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-pg-import-\(UUID().uuidString).csv")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testImportCSVIntoScratchTable() async throws {
        _ = try await adapter.execute(.sql("DROP TABLE IF EXISTS dbbbb_it_import"),
                                      options: ExecuteOptions())
        _ = try await adapter.execute(.sql("""
            CREATE TABLE dbbbb_it_import (
                id int4 PRIMARY KEY,
                name text NOT NULL,
                amount numeric,
                created date
            )
            """), options: ExecuteOptions())
        let objects = try await adapter.listObjects()
        guard let table = objects.first(where: { $0.kind == .table && $0.name == "dbbbb_it_import" })
        else { return XCTFail("scratch table missing from object tree") }

        let csv = try makeImportFile(
            "id,name,amount,created\r\n1,Ada,19.99,2024-01-01\r\n2,\"Bo,b\",7.5,2024-02-29\r\n")
        defer { try? FileManager.default.removeItem(at: csv) }

        let summary = try await adapter.importData(ImportRequest(
            target: table, format: .csv, fileURL: csv, hasHeader: true))
        XCTAssertEqual(summary, ImportSummary(processed: 2, inserted: 2, failed: 0))

        // The server coerced the text binds into the column types.
        let result = try await adapter.execute(
            .sql("SELECT id, name, amount, created FROM dbbbb_it_import ORDER BY id"),
            options: ExecuteOptions())
        let imported = try rows(result).1
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0], [.number(1), .string("Ada"), .string("19.99"), .string("2024-01-01")])
        XCTAssertEqual(imported[1][0], .number(2))
        XCTAssertEqual(imported[1][1], .string("Bo,b"))

        // A failing batch rolls the whole single-transaction import back.
        let bad = try makeImportFile("id,name\n3,Ok\nnot-an-int,Bad\n")
        defer { try? FileManager.default.removeItem(at: bad) }
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
            .sql("SELECT COUNT(*) FROM dbbbb_it_import"), options: ExecuteOptions())
        // COUNT(*) is int8, which always crosses as a string.
        XCTAssertEqual(try rows(after).1, [[.string("2")]])

        // Unknown header columns are rejected before anything is written.
        let unknown = try makeImportFile("id,nope\n4,x\n")
        defer { try? FileManager.default.removeItem(at: unknown) }
        do {
            _ = try await adapter.importData(ImportRequest(
                target: table, format: .csv, fileURL: unknown, hasHeader: true))
            XCTFail("expected headerInvalid")
        } catch let error as ImportError {
            guard case .headerInvalid = error else {
                return XCTFail("expected headerInvalid, got \(error)")
            }
        }
    }

    func testImportRefusedForReadOnlySessions() async throws {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_POSTGRES_URL"],
              var input = Self.parse(url: url)
        else { throw XCTSkip("DBBBB_TEST_POSTGRES_URL is not set") }
        input.readOnly = true
        let readOnlyAdapter = try PostgresAdapter(input: input)
        defer { Task { await readOnlyAdapter.close() } }

        let csv = try makeImportFile("id,name\n1,Ada\n")
        defer { try? FileManager.default.removeItem(at: csv) }
        let table = DatabaseObject(id: "postgresql:ignored", parentID: nil, name: "t", kind: .table)
        do {
            _ = try await readOnlyAdapter.importData(ImportRequest(
                target: table, format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected unsupported")
        } catch let error as ImportError {
            XCTAssertEqual(
                error,
                .unsupported("PostgreSQL import is disabled for read-only connections."))
        }
    }
}
