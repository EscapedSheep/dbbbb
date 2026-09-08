import Foundation
import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Create-statement introspection against real on-disk databases (same
/// pattern as SQLiteEditingTests): the stored CREATE text comes back
/// verbatim, missing/internal objects fail closed, and read-only profiles
/// may still read DDL.
final class SQLiteIntrospectionTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs = []
    }

    private func makeDatabase(sql: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-introspection-\(UUID().uuidString).sqlite")
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

    func testTableCreateStatementRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            """)
        let adapter = try makeAdapter(path: path)
        let ddl = try await adapter.createStatement(for: object(named: "people", kind: .table))
        XCTAssertEqual(ddl, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    }

    func testViewCreateStatementRoundTrip() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE VIEW people_names AS SELECT name FROM people;
            """)
        let adapter = try makeAdapter(path: path)
        let ddl = try await adapter.createStatement(for: object(named: "people_names", kind: .view))
        XCTAssertEqual(ddl, "CREATE VIEW people_names AS SELECT name FROM people")
    }

    func testQuotedNameLookupStaysParameterized() async throws {
        let path = try makeDatabase(sql: """
            CREATE TABLE "weird ""name" (id INTEGER);
            """)
        let adapter = try makeAdapter(path: path)
        let ddl = try await adapter.createStatement(for: object(named: #"weird "name"#, kind: .table))
        XCTAssertTrue(ddl.contains(#""weird ""name""#))
    }

    func testMissingObjectFailsClosed() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE people (id INTEGER);")
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.createStatement(for: object(named: "ghost", kind: .table))
            XCTFail("missing objects must fail closed")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testSchemaObjectFailsClosed() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE people (id INTEGER);")
        let adapter = try makeAdapter(path: path)
        do {
            _ = try await adapter.createStatement(for: object(named: "main", kind: .schema))
            XCTFail("schema objects must fail closed")
        } catch let error as AdapterError {
            guard case .notFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testReadOnlyProfileMayReadDDL() async throws {
        let path = try makeDatabase(sql: "CREATE TABLE people (id INTEGER);")
        let adapter = try makeAdapter(path: path, readOnly: true)
        let ddl = try await adapter.createStatement(for: object(named: "people", kind: .table))
        XCTAssertEqual(ddl, "CREATE TABLE people (id INTEGER)")
    }
}
