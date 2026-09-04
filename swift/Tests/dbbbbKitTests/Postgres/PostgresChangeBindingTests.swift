import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Unit tests for the adapter-side editing glue: record mapping against
/// catalog metadata and the DisplayValue → bind-text conversion.
final class PostgresChangeBindingTests: XCTestCase {
    private let metadata = PostgresChangeTableMetadata(
        columns: ["id", "status", "note"],
        columnTypeOIDs: ["id": 23, "status": 25, "note": 25],
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
        } catch let error as PostgresChangePlanError {
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
        let entries = try PostgresChangeMapper.orderedEntries(
            ["note": .string("n"), "id": .number(7)],
            metadata: metadata,
            label: "PostgreSQL original values")
        XCTAssertEqual(entries.map(\.column), ["id", "note"])
        XCTAssertEqual(entries.map(\.value), [.number(7), .string("n")])
    }

    func testOrderedEntriesRejectUnknownFields() {
        assertMapperThrows(containing: "unknown table field") {
            try PostgresChangeMapper.orderedEntries(
                ["id": .number(7), "status": .string("x"), "injected": .number(1)],
                metadata: metadata,
                label: "PostgreSQL original values")
        }
    }

    // MARK: currentEntries

    func testCurrentEntriesOverlayChangedValues() throws {
        let original: [PostgresFieldEntry] = [
            ("id", .number(7)), ("status", .string("draft")), ("note", .null),
        ]
        let current = try PostgresChangeMapper.currentEntries(
            original: original, changed: ["status": .string("paid"), "note": .string("ready")])
        XCTAssertEqual(current.map(\.column), ["id", "status", "note"])
        XCTAssertEqual(current.map(\.value), [.number(7), .string("paid"), .string("ready")])
    }

    func testCurrentEntriesRejectChangesOutsideTheOriginalRecord() {
        assertMapperThrows(containing: "must contain the same columns") {
            try PostgresChangeMapper.currentEntries(
                original: [("id", .number(7))],
                changed: ["status": .string("paid")])
        }
    }

    // MARK: primaryKeyEntries

    func testPrimaryKeyEntriesRequireOriginalValues() throws {
        let entries = try PostgresChangeMapper.primaryKeyEntries(
            metadata: metadata, original: [("id", .number(7)), ("status", .string("draft"))])
        XCTAssertEqual(entries.map(\.column), ["id"])
        XCTAssertEqual(entries.map(\.value), [.number(7)])

        assertMapperThrows(containing: "missing a primary-key value") {
            try PostgresChangeMapper.primaryKeyEntries(
                metadata: metadata, original: [("status", .string("draft"))])
        }
    }

    // MARK: bindColumns

    /// The mapper's bind-column order must line up with the planner's value
    /// order — this pins the pairing against the planner's own output.
    func testBindColumnsMatchPlannerValueOrder() throws {
        let primaryKey: [PostgresFieldEntry] = [("tenant_id", .number(7)), ("id", .string("order-1"))]
        let original: [PostgresFieldEntry] = [
            ("status", .string("draft")), ("note", .null), ("unchanged", .number(4)),
        ]
        let current: [PostgresFieldEntry] = [
            ("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4)),
        ]
        let plan = try PostgresChangePlanner.planUpdate(
            schema: "sales", table: "orders", columnTypeOIDs: [:],
            primaryKey: primaryKey, original: original, current: current)
        let columns = PostgresChangeMapper.bindColumns(
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
        let primaryKey: [PostgresFieldEntry] = [("id", .number(42))]
        let original: [PostgresFieldEntry] = [
            ("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true)),
        ]
        let plan = try PostgresChangePlanner.planDelete(
            schema: "public", table: "users", columnTypeOIDs: [:],
            primaryKey: primaryKey, original: original)
        let columns = PostgresChangeMapper.bindColumns(
            primaryKey: primaryKey, original: original, current: nil)
        XCTAssertEqual(columns, ["id", "email", "active"])
        XCTAssertEqual(columns.count, plan.values.count)
    }

    // MARK: bindText

    func testBindTextScalars() throws {
        XCTAssertNil(try PostgresChangeMapper.bindText(for: .null, label: "c"))
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .bool(true), label: "c"), "true")
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .bool(false), label: "c"), "false")
        // Integral numbers bind without a decimal point (`int4` rejects "5.0").
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .number(5), label: "c"), "5")
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .number(-42), label: "c"), "-42")
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .number(1.5), label: "c"), "1.5")
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .string("plain"), label: "c"), "plain")
        XCTAssertEqual(
            try PostgresChangeMapper.bindText(for: .string("2024-02-29 01:02:03.456789"), label: "c"),
            "2024-02-29 01:02:03.456789")
        XCTAssertEqual(
            try PostgresChangeMapper.bindText(for: .binary(Data([0xDE, 0xAD])), label: "c"),
            "\\xdead")
    }

    func testBindTextArrays() throws {
        XCTAssertEqual(
            try PostgresChangeMapper.bindText(
                for: .array([.number(1), .null, .number(3)]), label: "c"),
            #"{"1",NULL,"3"}"#)
        XCTAssertEqual(
            try PostgresChangeMapper.bindText(
                for: .array([.string(#"a"b\c"#), .bool(true)]), label: "c"),
            #"{"a\"b\\c","true"}"#)
        XCTAssertEqual(
            try PostgresChangeMapper.bindText(
                for: .array([.array([.number(1), .number(2)]), .array([])]), label: "c"),
            #"{{"1","2"},{}}"#)
        XCTAssertEqual(try PostgresChangeMapper.bindText(for: .array([]), label: "c"), "{}")
    }

    func testBindTextRejectsNonBindableValues() {
        assertMapperThrows(containing: "not a PostgreSQL value") {
            try PostgresChangeMapper.bindText(for: .object([("a", .number(1))]), label: "c")
        }
        assertMapperThrows(containing: "not a finite number") {
            try PostgresChangeMapper.bindText(for: .number(.infinity), label: "c")
        }
    }
}
