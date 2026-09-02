import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

final class SQLiteChangePlannerTests: XCTestCase {
    private func assertPlanThrows(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> SQLiteParameterizedPlan
    ) {
        do {
            _ = try body()
            XCTFail("Expected plan to throw", file: file, line: line)
        } catch let error as SQLiteChangePlanError {
            XCTAssertTrue(
                error.userMessage.contains(fragment),
                "\(error.userMessage) should contain \(fragment)",
                file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    func testCompositeKeyUpdateIsParameterizedWithNullSafePredicates() throws {
        let plan = try SQLiteChangePlanner.planUpdate(
            table: "order\"line",
            primaryKey: [("tenant_id", .number(7)), ("id", .string("order-1"))],
            original: [("status", .string("draft")), ("note", .null), ("unchanged", .number(4))],
            current: [("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4))])

        XCTAssertEqual(plan.text, [
            "UPDATE \"order\"\"line\"",
            "SET \"status\" = ?,",
            "    \"note\" = ?",
            "WHERE \"tenant_id\" IS ?",
            "  AND \"id\" IS ?",
            "  AND \"status\" IS ?",
            "  AND \"note\" IS ?",
            "  AND \"unchanged\" IS ?",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [
            .string("paid"), .string("ready"),
            .number(7), .string("order-1"),
            .string("draft"), .null, .number(4),
        ])
    }

    func testDeleteMatchesIdentityAndOriginalValues() throws {
        let plan = try SQLiteChangePlanner.planDelete(
            table: "users",
            primaryKey: [("id", .number(42))],
            original: [("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true))])

        XCTAssertEqual(plan.text, [
            "DELETE FROM \"users\"",
            "WHERE \"id\" IS ?",
            "  AND \"email\" IS ?",
            "  AND \"active\" IS ?",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.number(42), .string("before@example.test"), .bool(true)])
    }

    func testQuotesIdentifiersAndNeverInterpolatesValues() throws {
        let hostileValue = "x'); DROP TABLE audit; --"
        let plan = try SQLiteChangePlanner.planUpdate(
            table: "users\"; DROP TABLE audit; --",
            primaryKey: [("id", .number(1))],
            original: [("display_name", .string("before"))],
            current: [("display_name", .string(hostileValue))])

        XCTAssertEqual(try SQLiteChangePlanner.quoteIdentifier("a.b\"c"), "\"a.b\"\"c\"")
        XCTAssertTrue(plan.text.contains("UPDATE \"users\"\"; DROP TABLE audit; --\""))
        XCTAssertFalse(plan.text.contains(hostileValue))
        XCTAssertEqual(plan.values.first, .string(hostileValue))
    }

    func testRejectsMissingIdentityEmptyPatchesAndPrimaryKeyEdits() {
        assertPlanThrows(containing: "primary-key") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [],
                original: [("name", .string("before"))],
                current: [("name", .string("after"))])
        }
        assertPlanThrows(containing: "original values") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [],
                current: [])
        }
        assertPlanThrows(containing: "changed value") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("name", .string("same"))],
                current: [("name", .string("same"))])
        }
        assertPlanThrows(containing: "cannot be edited") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("id", .number(1)), ("name", .string("before"))],
                current: [("id", .number(2)), ("name", .string("before"))])
        }
    }

    func testRejectsAmbiguousPatchesAndDangerousKeys() {
        assertPlanThrows(containing: "same columns") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("first_name", .string("before"))],
                current: [("display_name", .string("after"))])
        }
        assertPlanThrows(containing: "dangerous key") {
            try SQLiteChangePlanner.planUpdate(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("__proto__", .string("value"))],
                current: [("__proto__", .string("value2"))])
        }
        assertPlanThrows(containing: "cannot be null") {
            try SQLiteChangePlanner.planDelete(
                table: "users",
                primaryKey: [("id", .null)],
                original: [("id", .null)])
        }
        assertPlanThrows(containing: "inconsistent") {
            try SQLiteChangePlanner.planDelete(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("id", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try SQLiteChangePlanner.planDelete(
                table: "users",
                primaryKey: [("id", .number(1))],
                original: [("bad\u{0}name", .number(1))])
        }
    }

    func testQuoteIdentifierRejectsEmptyAndNUL() {
        XCTAssertThrowsError(try SQLiteChangePlanner.quoteIdentifier(""))
        XCTAssertThrowsError(try SQLiteChangePlanner.quoteIdentifier("a\u{0}b"))
    }

    // MARK: - Metadata validation

    func testChangeTableMetadataFoldsRowsAndOrdersPrimaryKey() throws {
        let metadata = try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("id", "integer", 2),
            ("tenant_id", "bigint", 1),
            ("note", "text", 0),
        ])
        XCTAssertEqual(metadata.columns, ["id", "tenant_id", "note"])
        XCTAssertEqual(metadata.primaryKey, ["tenant_id", "id"])
        XCTAssertEqual(metadata.columnTypes["id"], "INTEGER")
    }

    func testChangeTableMetadataRejectsInvalidShape() {
        XCTAssertThrowsError(try SQLiteChangePlanner.changeTableMetadata(rows: []))
        // No primary key (also covers views, whose pk ordinals are all zero).
        XCTAssertThrowsError(try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("note", "text", 0),
        ]))
        // Duplicate column.
        XCTAssertThrowsError(try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("id", "integer", 1),
            ("id", "integer", 0),
        ]))
        // Duplicate ordinal.
        XCTAssertThrowsError(try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("a", "integer", 1),
            ("b", "integer", 1),
        ]))
        // Non-contiguous ordinals.
        XCTAssertThrowsError(try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("a", "integer", 1),
            ("b", "integer", 3),
        ]))
    }
}
