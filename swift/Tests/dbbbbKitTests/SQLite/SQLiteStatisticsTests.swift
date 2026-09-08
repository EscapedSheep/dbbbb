import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Table statistics against real on-disk databases (ROADMAP M2 ⑩, same
/// pattern as SQLiteIntrospectionTests): COUNT(*) is the truthful row count,
/// sizes come from the page_count × page_size pragmas (whole-file scope is
/// labeled), views report rows only, and read-only profiles may read stats.
final class SQLiteStatisticsTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase(sql: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-statistics-\(UUID().uuidString).sqlite")
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

    private func object(named name: String, kind: DatabaseObjectKind) -> DatabaseObject {
        DatabaseObject(
            id: SQLiteAdapter.objectID(kind: kind, name: name),
            parentID: nil,
            name: name,
            kind: kind)
    }

    func testTableStatisticsRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
            CREATE INDEX items_name_idx ON items (name);
            INSERT INTO items (name) VALUES ('a'), ('b'), ('c');
            """)
        let adapter = try makeAdapter(path: path)

        let stats = try await adapter.tableStatistics(for: object(named: "items", kind: .table))
        XCTAssertEqual(stats.estimatedRows, 3)
        // Whole-file size from the pragmas: a real database always has pages.
        let totalBytes = try XCTUnwrap(stats.totalBytes)
        XCTAssertGreaterThan(totalBytes, 0)
        XCTAssertEqual(totalBytes % 512, 0, "page_count × page_size is a multiple of the page size")
        XCTAssertNil(stats.indexBytes)
        XCTAssertEqual(stats.extras, [TableStatistics.Entry(
            name: "Size scope", value: "Whole database file")])
    }

    func testViewStatisticsReportRowsOnly() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT);
            INSERT INTO items (name) VALUES ('a'), ('b');
            CREATE VIEW item_names AS SELECT name FROM items;
            """)
        let adapter = try makeAdapter(path: path)

        let stats = try await adapter.tableStatistics(for: object(named: "item_names", kind: .view))
        XCTAssertEqual(stats.estimatedRows, 2)
        XCTAssertNil(stats.totalBytes)
        XCTAssertNil(stats.indexBytes)
        XCTAssertTrue(stats.extras.isEmpty)
    }

    func testReadOnlyProfileMayReadStatistics() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE items (id INTEGER PRIMARY KEY);
            INSERT INTO items DEFAULT VALUES;
            """)
        let adapter = try makeAdapter(path: path, readOnly: true)
        let stats = try await adapter.tableStatistics(for: object(named: "items", kind: .table))
        XCTAssertEqual(stats.estimatedRows, 1)
    }

    func testUnknownTableFailsClosed() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.tableStatistics(for: object(named: "ghost", kind: .table))
            XCTFail("expected a sanitized error for a missing table")
        } catch let error as SQLiteAdapterError {
            XCTAssertFalse(error.userMessage.contains(path), "the file path must not leak")
        }
    }

    func testSchemaTargetFailsClosed() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY);")
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.tableStatistics(for: object(named: "main", kind: .schema))
            XCTFail("schema targets must fail closed")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
