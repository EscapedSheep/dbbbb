import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Unit tests for the adapter-side editing glue: record mapping against
/// catalog metadata and the DisplayValue → `MySQLData` bind conversion.
final class MySQLChangeBindingTests: XCTestCase {
    private let metadata = MySQLChangeTableMetadata(
        columns: ["id", "status", "note"],
        columnTypes: ["id": "int", "status": "varchar", "note": "text"],
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
        } catch let error as MySQLChangePlanError {
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
        let entries = try MySQLChangeMapper.orderedEntries(
            ["note": .string("n"), "id": .number(7)],
            metadata: metadata,
            label: "MySQL original values")
        XCTAssertEqual(entries.map(\.column), ["id", "note"])
        XCTAssertEqual(entries.map(\.value), [.number(7), .string("n")])
    }

    func testOrderedEntriesRejectUnknownFields() {
        assertMapperThrows(containing: "unknown table field") {
            try MySQLChangeMapper.orderedEntries(
                ["id": .number(7), "status": .string("x"), "injected": .number(1)],
                metadata: metadata,
                label: "MySQL original values")
        }
    }

    // MARK: currentEntries

    func testCurrentEntriesOverlayChangedValues() throws {
        let original: [MySQLFieldEntry] = [
            ("id", .number(7)), ("status", .string("draft")), ("note", .null),
        ]
        let current = try MySQLChangeMapper.currentEntries(
            original: original, changed: ["status": .string("paid"), "note": .string("ready")])
        XCTAssertEqual(current.map(\.column), ["id", "status", "note"])
        XCTAssertEqual(current.map(\.value), [.number(7), .string("paid"), .string("ready")])
    }

    func testCurrentEntriesRejectChangesOutsideTheOriginalRecord() {
        assertMapperThrows(containing: "must contain the same columns") {
            try MySQLChangeMapper.currentEntries(
                original: [("id", .number(7))],
                changed: ["status": .string("paid")])
        }
    }

    // MARK: primaryKeyEntries

    func testPrimaryKeyEntriesRequireOriginalValues() throws {
        let entries = try MySQLChangeMapper.primaryKeyEntries(
            metadata: metadata, original: [("id", .number(7)), ("status", .string("draft"))])
        XCTAssertEqual(entries.map(\.column), ["id"])
        XCTAssertEqual(entries.map(\.value), [.number(7)])

        assertMapperThrows(containing: "missing a primary-key value") {
            try MySQLChangeMapper.primaryKeyEntries(
                metadata: metadata, original: [("status", .string("draft"))])
        }
    }

    // MARK: bindColumns

    /// The mapper's bind-column order must line up with the planner's value
    /// order — this pins the pairing against the planner's own output.
    func testBindColumnsMatchPlannerValueOrder() throws {
        let primaryKey: [MySQLFieldEntry] = [("tenant_id", .number(7)), ("id", .string("order-1"))]
        let original: [MySQLFieldEntry] = [
            ("status", .string("draft")), ("note", .null), ("unchanged", .number(4)),
        ]
        let current: [MySQLFieldEntry] = [
            ("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4)),
        ]
        let plan = try MySQLChangePlanner.planUpdate(
            database: "sales", table: "orders",
            primaryKey: primaryKey, original: original, current: current)
        let columns = MySQLChangeMapper.bindColumns(
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
        let primaryKey: [MySQLFieldEntry] = [("id", .number(42))]
        let original: [MySQLFieldEntry] = [
            ("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true)),
        ]
        let plan = try MySQLChangePlanner.planDelete(
            database: "shop", table: "users", primaryKey: primaryKey, original: original)
        let columns = MySQLChangeMapper.bindColumns(
            primaryKey: primaryKey, original: original, current: nil)
        XCTAssertEqual(columns, ["id", "email", "active"])
        XCTAssertEqual(columns.count, plan.values.count)
    }

    // MARK: bind

    func testBindScalars() throws {
        let nullBind = try MySQLChangeMapper.bind(for: .null, label: "c")
        XCTAssertNil(nullBind.buffer)

        let boolBind = try MySQLChangeMapper.bind(for: .bool(true), label: "c")
        XCTAssertEqual(boolBind.type, .tiny)
        XCTAssertEqual(boolBind.bool, true)

        // Integral numbers bind as integers so exact integer/decimal
        // comparisons never pass through floating point.
        let intBind = try MySQLChangeMapper.bind(for: .number(-42), label: "c")
        XCTAssertEqual(intBind.type, .longlong)
        XCTAssertEqual(intBind.int, -42)

        let doubleBind = try MySQLChangeMapper.bind(for: .number(1.5), label: "c")
        XCTAssertEqual(doubleBind.type, .double)
        XCTAssertEqual(doubleBind.double, 1.5)

        let stringBind = try MySQLChangeMapper.bind(
            for: .string("2024-02-29 01:02:03.456789"), label: "c")
        XCTAssertEqual(stringBind.type, .varString)
        XCTAssertEqual(stringBind.string, "2024-02-29 01:02:03.456789")

        let binaryBind = try MySQLChangeMapper.bind(for: .binary(Data([0xDE, 0xAD])), label: "c")
        XCTAssertEqual(binaryBind.type, .blob)
        let bytes = binaryBind.buffer.map {
            $0.getBytes(at: $0.readerIndex, length: $0.readableBytes) ?? []
        }
        XCTAssertEqual(bytes, [0xDE, 0xAD])
    }

    func testBindRejectsNonBindableValues() {
        assertMapperThrows(containing: "not a MySQL value") {
            try MySQLChangeMapper.bind(for: .array([.number(1)]), label: "c")
        }
        assertMapperThrows(containing: "not a MySQL value") {
            try MySQLChangeMapper.bind(for: .object([("a", .number(1))]), label: "c")
        }
        assertMapperThrows(containing: "not a finite number") {
            try MySQLChangeMapper.bind(for: .number(.infinity), label: "c")
        }
    }
}
