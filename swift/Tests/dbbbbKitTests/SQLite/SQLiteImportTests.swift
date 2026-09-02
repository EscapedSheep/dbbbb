import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Import tests against real on-disk databases (no server needed, so no
/// environment gating): affinity coercion, failure rollback, read-only
/// refusal, and cancellation.
final class SQLiteImportTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase() throws -> (url: URL, path: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-import-\(UUID().uuidString).sqlite")
        temporaryURLs.append(url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE people (
                    id INTEGER PRIMARY KEY,
                    name TEXT NOT NULL,
                    score REAL,
                    note TEXT
                )
                """)
        }
        return (url, url.path)
    }

    private func makeCSV(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-import-\(UUID().uuidString).csv")
        try Data(contents.utf8).write(to: url)
        temporaryURLs.append(url)
        return url
    }

    private func target(named name: String) -> DatabaseObject {
        DatabaseObject(
            id: SQLiteAdapter.objectID(kind: .table, name: name),
            parentID: nil,
            name: name,
            kind: .table)
    }

    private func rows(_ result: QueryResult) throws -> [[DisplayValue]] {
        guard case .rows(_, let rows, _) = result else {
            throw SQLiteAdapterError("expected rows")
        }
        return rows
    }

    func testImportWithHeaderCoercesViaColumnAffinity() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("id,name,score,note\r\n1,Ada,9.5,\r\n2,Bob,7,\"x,y\"\r\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        let summary = try await adapter.importData(ImportRequest(
            target: target(named: "people"), format: .csv, fileURL: csv, hasHeader: true))
        XCTAssertEqual(summary, ImportSummary(processed: 2, inserted: 2, failed: 0))

        let result = try await adapter.execute(
            .sql("SELECT id, name, score, note FROM people ORDER BY id"),
            options: ExecuteOptions())
        XCTAssertEqual(try rows(result), [
            [.number(1), .string("Ada"), .number(9.5), .string("")],
            [.number(2), .string("Bob"), .number(7), .string("x,y")],
        ])
    }

    func testImportWithoutHeaderUsesTableColumns() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("1,Ada,9.5,hi\n2,Bob,7,yo\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        let summary = try await adapter.importData(ImportRequest(
            target: target(named: "people"), format: .csv, fileURL: csv, hasHeader: false))
        XCTAssertEqual(summary, ImportSummary(processed: 2, inserted: 2, failed: 0))
    }

    func testImportRejectsUnknownHeaderColumns() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("id,unknown\n1,2\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        do {
            _ = try await adapter.importData(ImportRequest(
                target: target(named: "people"), format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected headerInvalid")
        } catch let error as ImportError {
            guard case .headerInvalid = error else {
                return XCTFail("expected headerInvalid, got \(error)")
            }
        }
        let result = try await adapter.execute(.sql("SELECT COUNT(*) FROM people"), options: ExecuteOptions())
        XCTAssertEqual(try rows(result), [[.number(0)]])
    }

    func testImportConstraintFailureRollsBackTheBatch() async throws {
        let (_, path) = try makeDatabase()
        // One batch: the duplicate id fails the whole batch atomically.
        let csv = try makeCSV("id,name\n1,Ada\n1,Again\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        do {
            _ = try await adapter.importData(ImportRequest(
                target: target(named: "people"), format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected insertFailed")
        } catch let error as ImportError {
            guard case .insertFailed(let record, let detail) = error else {
                return XCTFail("expected insertFailed, got \(error)")
            }
            XCTAssertEqual(record, 2)
            // Redaction: the database file path never leaks.
            XCTAssertFalse(detail.contains(path))
            XCTAssertFalse(error.userMessage.contains(path))
        }
        let result = try await adapter.execute(.sql("SELECT COUNT(*) FROM people"), options: ExecuteOptions())
        XCTAssertEqual(try rows(result), [[.number(0)]])
    }

    func testImportRefusedForReadOnlyConnections() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("id,name\n1,Ada\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path, readOnly: true))
        defer { Task { await adapter.close() } }

        do {
            _ = try await adapter.importData(ImportRequest(
                target: target(named: "people"), format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected unsupported")
        } catch let error as ImportError {
            XCTAssertEqual(
                error,
                .unsupported("SQLite import is disabled for read-only connections."))
        }
    }

    func testImportRejectsWrongFormatAndTargets() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("id,name\n1,Ada\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        do {
            _ = try await adapter.importData(ImportRequest(
                target: target(named: "people"), format: .jsonl, fileURL: csv, hasHeader: true))
            XCTFail("expected unsupported")
        } catch let error as ImportError {
            guard case .unsupported = error else {
                return XCTFail("expected unsupported, got \(error)")
            }
        }
        let view = DatabaseObject(
            id: SQLiteAdapter.objectID(kind: .view, name: "v"),
            parentID: nil, name: "v", kind: .view)
        do {
            _ = try await adapter.importData(ImportRequest(
                target: view, format: .csv, fileURL: csv, hasHeader: true))
            XCTFail("expected notFound")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testImportCancellationInsertsNothing() async throws {
        let (_, path) = try makeDatabase()
        let csv = try makeCSV("id,name\n1,Ada\n2,Bob\n")
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: path))
        defer { Task { await adapter.close() } }

        do {
            _ = try await adapter.importData(ImportRequest(
                target: target(named: "people"), format: .csv, fileURL: csv,
                hasHeader: true, isCancelled: { true }))
            XCTFail("expected cancelled")
        } catch let error as ImportError {
            XCTAssertEqual(error, .cancelled)
        }
        let result = try await adapter.execute(.sql("SELECT COUNT(*) FROM people"), options: ExecuteOptions())
        XCTAssertEqual(try rows(result), [[.number(0)]])
    }
}
