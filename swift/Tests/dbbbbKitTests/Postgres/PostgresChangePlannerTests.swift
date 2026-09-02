import XCTest
import dbbbbCore
@testable import dbbbbKit

final class PostgresChangePlannerTests: XCTestCase {
    private func assertPlanThrows(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> PostgresParameterizedPlan
    ) {
        do {
            _ = try body()
            XCTFail("Expected plan to throw", file: file, line: line)
        } catch let error as PostgresChangePlanError {
            XCTAssertTrue(
                error.userMessage.contains(fragment),
                "\(error.userMessage) should contain \(fragment)",
                file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    func testCompositeKeyUpdateIsParameterizedWithOptimisticPredicates() throws {
        let plan = try PostgresChangePlanner.planUpdate(
            schema: "sales.ops",
            table: "order\"line",
            primaryKey: [("tenant_id", .number(7)), ("id", .string("order-1"))],
            original: [("status", .string("draft")), ("note", .null), ("unchanged", .number(4))],
            current: [("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4))])

        XCTAssertEqual(plan.text, [
            "UPDATE \"sales.ops\".\"order\"\"line\"",
            "SET \"status\" = $1,",
            "    \"note\" = $2",
            "WHERE \"tenant_id\" IS NOT DISTINCT FROM $3",
            "  AND \"id\" IS NOT DISTINCT FROM $4",
            "  AND \"status\" IS NOT DISTINCT FROM $5",
            "  AND \"note\" IS NOT DISTINCT FROM $6",
            "  AND \"unchanged\" IS NOT DISTINCT FROM $7",
            "RETURNING *;",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [
            .string("paid"), .string("ready"),
            .number(7), .string("order-1"),
            .string("draft"), .null, .number(4),
        ])
    }

    func testDeleteMatchesIdentityAndOriginalValues() throws {
        let plan = try PostgresChangePlanner.planDelete(
            schema: "public",
            table: "users",
            primaryKey: [("id", .number(42))],
            original: [("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true))])

        XCTAssertEqual(plan.text, [
            "DELETE FROM \"public\".\"users\"",
            "WHERE \"id\" IS NOT DISTINCT FROM $1",
            "  AND \"email\" IS NOT DISTINCT FROM $2",
            "  AND \"active\" IS NOT DISTINCT FROM $3",
            "RETURNING *;",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.number(42), .string("before@example.test"), .bool(true)])
    }

    func testQuotesIdentifiersIndependentlyAndNeverInterpolatesValues() throws {
        let hostileValue = "x'); DROP TABLE audit; --"
        let plan = try PostgresChangePlanner.planUpdate(
            schema: "public",
            table: "users\"; DROP TABLE audit; --",
            primaryKey: [("id", .number(1))],
            original: [("display_name", .string("before"))],
            current: [("display_name", .string(hostileValue))])

        XCTAssertEqual(try PostgresChangePlanner.quoteIdentifier("a.b\"c"), "\"a.b\"\"c\"")
        XCTAssertTrue(plan.text.contains("UPDATE \"public\".\"users\"\"; DROP TABLE audit; --\""))
        XCTAssertFalse(plan.text.contains(hostileValue))
        XCTAssertEqual(plan.values.first, .string(hostileValue))
    }

    func testRejectsMissingIdentityEmptyPatchesAndPrimaryKeyEdits() {
        assertPlanThrows(containing: "primary-key") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [],
                original: [("name", .string("before"))],
                current: [("name", .string("after"))])
        }
        assertPlanThrows(containing: "original values") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [],
                current: [])
        }
        assertPlanThrows(containing: "changed value") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("name", .string("same"))],
                current: [("name", .string("same"))])
        }
        assertPlanThrows(containing: "cannot be edited") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("id", .number(1)), ("name", .string("before"))],
                current: [("id", .number(2)), ("name", .string("before"))])
        }
    }

    func testRejectsAmbiguousPatchesAndDangerousKeys() {
        assertPlanThrows(containing: "same columns") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("first_name", .string("before"))],
                current: [("display_name", .string("after"))])
        }
        assertPlanThrows(containing: "dangerous key") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("__proto__", .string("value"))],
                current: [("__proto__", .string("value2"))])
        }
        assertPlanThrows(containing: "cannot be null") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users",
                primaryKey: [("id", .null)],
                original: [("id", .null)])
        }
        assertPlanThrows(containing: "inconsistent") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("id", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users",
                primaryKey: [("id", .number(1))],
                original: [("bad\u{0}name", .number(1))])
        }
    }

    func testQuoteIdentifierRejectsEmptyAndNUL() {
        XCTAssertThrowsError(try PostgresChangePlanner.quoteIdentifier(""))
        XCTAssertThrowsError(try PostgresChangePlanner.quoteIdentifier("a\u{0}b"))
    }

    // MARK: - Metadata validation

    func testChangeTableMetadataFoldsRowsAndOrdersPrimaryKey() throws {
        let metadata = try PostgresChangePlanner.changeTableMetadata(rows: [
            ("id", 23, "int4", 2),
            ("tenant_id", 20, "int8", 1),
            ("note", 25, "text", 0),
        ])
        XCTAssertEqual(metadata.columns, ["id", "tenant_id", "note"])
        XCTAssertEqual(metadata.primaryKey, ["tenant_id", "id"])
        XCTAssertEqual(metadata.columnTypeOIDs["id"], 23)
    }

    func testChangeTableMetadataRejectsNonRoundTrippingTypes() {
        for typeName in ["json", "interval", "money", "int4range", "tstzrange", "_json", "nummultirange"] {
            XCTAssertThrowsError(
                try PostgresChangePlanner.changeTableMetadata(rows: [
                    ("id", 23, "int4", 1),
                    ("payload", 114, typeName, 0),
                ]),
                "type \(typeName) must be rejected"
            ) { error in
                guard let planError = error as? PostgresChangePlanError else {
                    return XCTFail("Unexpected error \(error)")
                }
                XCTAssertTrue(planError.userMessage.contains("payload"), planError.userMessage)
                XCTAssertTrue(planError.userMessage.contains(typeName), planError.userMessage)
            }
        }
        // jsonb round-trips fine.
        XCTAssertNoThrow(try PostgresChangePlanner.changeTableMetadata(rows: [
            ("id", 23, "int4", 1),
            ("payload", 3802, "jsonb", 0),
        ]))
    }

    func testChangeTableMetadataRejectsInvalidShape() {
        XCTAssertThrowsError(try PostgresChangePlanner.changeTableMetadata(rows: []))
        // No primary key.
        XCTAssertThrowsError(try PostgresChangePlanner.changeTableMetadata(rows: [
            ("note", 25, "text", 0),
        ]))
        // Duplicate column.
        XCTAssertThrowsError(try PostgresChangePlanner.changeTableMetadata(rows: [
            ("id", 23, "int4", 1),
            ("id", 23, "int4", 0),
        ]))
        // Duplicate ordinal.
        XCTAssertThrowsError(try PostgresChangePlanner.changeTableMetadata(rows: [
            ("a", 23, "int4", 1),
            ("b", 23, "int4", 1),
        ]))
        // Non-contiguous ordinals.
        XCTAssertThrowsError(try PostgresChangePlanner.changeTableMetadata(rows: [
            ("a", 23, "int4", 1),
            ("b", 23, "int4", 3),
        ]))
    }
}
