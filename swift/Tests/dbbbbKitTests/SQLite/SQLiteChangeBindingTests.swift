import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

/// Unit tests for the adapter-side editing glue: record mapping against
/// catalog metadata and the DisplayValue → `DatabaseValue` bind conversion.
final class SQLiteChangeBindingTests: XCTestCase {
    private let metadata = SQLiteChangeTableMetadata(
        columns: ["id", "status", "note"],
        columnTypes: ["id": "INTEGER", "status": "TEXT", "note": "TEXT"],
        primaryKey: ["id"])

    private func assertMapperThrows(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> some Any
    ) {
        do {
            _ = try body()
            XCTFail("Expected mapper to throw", file: file, line: line)
        } catch let error as SQLiteChangePlanError {
            XCTAssertTrue(
                error.userMessage.contains(fragment),
                "\(error.userMessage) should contain \(fragment)",
                file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    // MARK: orderedEntries

    func testOrderedEntriesFollowCatalogOrderAndSkipMissingColumns() throws {
        let entries = try SQLiteChangeMapper.orderedEntries(
            ["note": .string("n"), "id": .number(7)],
            metadata: metadata,
            label: "SQLite original values")
        XCTAssertEqual(entries.map(\.column), ["id", "note"])
        XCTAssertEqual(entries.map(\.value), [.number(7), .string("n")])
    }

    func testOrderedEntriesRejectUnknownFields() {
        assertMapperThrows(containing: "unknown table field") {
            try SQLiteChangeMapper.orderedEntries(
                ["id": .number(7), "status": .string("x"), "injected": .number(1)],
                metadata: metadata,
                label: "SQLite original values")
        }
    }

    // MARK: currentEntries

    func testCurrentEntriesOverlayChangedValues() throws {
        let original: [SQLiteFieldEntry] = [
            ("id", .number(7)), ("status", .string("draft")), ("note", .null),
        ]
        let current = try SQLiteChangeMapper.currentEntries(
            original: original, changed: ["status": .string("paid"), "note": .string("ready")])
        XCTAssertEqual(current.map(\.column), ["id", "status", "note"])
        XCTAssertEqual(current.map(\.value), [.number(7), .string("paid"), .string("ready")])
    }

    func testCurrentEntriesRejectChangesOutsideTheOriginalRecord() {
        assertMapperThrows(containing: "must contain the same columns") {
            try SQLiteChangeMapper.currentEntries(
                original: [("id", .number(7))],
                changed: ["status": .string("paid")])
        }
    }

    // MARK: primaryKeyEntries

    func testPrimaryKeyEntriesRequireOriginalValues() throws {
        let entries = try SQLiteChangeMapper.primaryKeyEntries(
            metadata: metadata, original: [("id", .number(7)), ("status", .string("draft"))])
        XCTAssertEqual(entries.map(\.column), ["id"])
        XCTAssertEqual(entries.map(\.value), [.number(7)])

        assertMapperThrows(containing: "missing a primary-key value") {
            try SQLiteChangeMapper.primaryKeyEntries(
                metadata: metadata, original: [("status", .string("draft"))])
        }
    }

    // MARK: bindColumns

    /// The mapper's bind-column order must line up with the planner's value
    /// order — this pins the pairing against the planner's own output.
    func testBindColumnsMatchPlannerValueOrder() throws {
        let primaryKey: [SQLiteFieldEntry] = [("tenant_id", .number(7)), ("id", .string("order-1"))]
        let original: [SQLiteFieldEntry] = [
            ("status", .string("draft")), ("note", .null), ("unchanged", .number(4)),
        ]
        let current: [SQLiteFieldEntry] = [
            ("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4)),
        ]
        let plan = try SQLiteChangePlanner.planUpdate(
            table: "orders", columnTypes: [:],
            primaryKey: primaryKey, original: original, current: current)
        let columns = SQLiteChangeMapper.bindColumns(
            primaryKey: primaryKey, original: original, current: current)

        XCTAssertEqual(columns.count, plan.values.count)
        let pairs = Array(zip(columns, plan.values))
        XCTAssertEqual(pairs[0].0, "status"); XCTAssertEqual(pairs[0].1, .string("paid"))
        XCTAssertEqual(pairs[1].0, "note"); XCTAssertEqual(pairs[1].1, .string("ready"))
        XCTAssertEqual(pairs[2].0, "tenant_id"); XCTAssertEqual(pairs[2].1, .number(7))
        XCTAssertEqual(pairs[3].0, "id"); XCTAssertEqual(pairs[3].1, .string("order-1"))
        XCTAssertEqual(pairs[4].0, "status"); XCTAssertEqual(pairs[4].1, .string("draft"))
        XCTAssertEqual(pairs[5].0, "note"); XCTAssertEqual(pairs[5].1, .null)
        XCTAssertEqual(pairs[6].0, "unchanged"); XCTAssertEqual(pairs[6].1, .number(4))
    }

    func testBindColumnsForDelete() throws {
        let primaryKey: [SQLiteFieldEntry] = [("id", .number(42))]
        let original: [SQLiteFieldEntry] = [
            ("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true)),
        ]
        let plan = try SQLiteChangePlanner.planDelete(
            table: "users", columnTypes: [:], primaryKey: primaryKey, original: original)
        let columns = SQLiteChangeMapper.bindColumns(
            primaryKey: primaryKey, original: original, current: nil)
        XCTAssertEqual(columns, ["id", "email", "active"])
        XCTAssertEqual(columns.count, plan.values.count)
    }

    // MARK: bind

    /// `IS` compares storage classes strictly, so binds must keep the class
    /// the value was displayed from: integral numbers are INTEGER unless the
    /// column has REAL affinity.
    func testBindPreservesStorageClass() throws {
        XCTAssertEqual(try SQLiteChangeMapper.bind(for: .null, columnType: "TEXT", label: "c"), .null)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .bool(true), columnType: "INTEGER", label: "c"),
            Int64(1).databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(5), columnType: "INTEGER", label: "c"),
            Int64(5).databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(5), columnType: "NUMERIC", label: "c"),
            Int64(5).databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(5), columnType: "REAL", label: "c"),
            5.0.databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(5), columnType: "DOUBLE PRECISION", label: "c"),
            5.0.databaseValue)
        // "POINT" contains INT, so it is INTEGER affinity, never REAL.
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(5), columnType: "POINT", label: "c"),
            Int64(5).databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .number(1.5), columnType: "INTEGER", label: "c"),
            1.5.databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .string("plain"), columnType: "TEXT", label: "c"),
            "plain".databaseValue)
        XCTAssertEqual(
            try SQLiteChangeMapper.bind(for: .binary(Data([0xDE, 0xAD])), columnType: "BLOB", label: "c"),
            Data([0xDE, 0xAD]).databaseValue)
    }

    func testBindRejectsNonBindableValues() {
        assertMapperThrows(containing: "not a SQLite value") {
            try SQLiteChangeMapper.bind(for: .array([.number(1)]), columnType: "TEXT", label: "c")
        }
        assertMapperThrows(containing: "not a SQLite value") {
            try SQLiteChangeMapper.bind(
                for: .object([("a", .number(1))]), columnType: "TEXT", label: "c")
        }
        assertMapperThrows(containing: "not a finite number") {
            try SQLiteChangeMapper.bind(for: .number(.infinity), columnType: "REAL", label: "c")
        }
    }
}
