import XCTest
import dbbbbCore
@testable import dbbbbKit

final class MySQLChangePlannerTests: XCTestCase {
    private func assertPlanThrows(
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> MySQLParameterizedPlan
    ) {
        do {
            _ = try body()
            XCTFail("Expected plan to throw", file: file, line: line)
        } catch let error as MySQLChangePlanError {
            XCTAssertTrue(
                error.userMessage.contains(fragment),
                "\(error.userMessage) should contain \(fragment)",
                file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    func testCompositeKeyUpdateIsParameterizedWithNullSafePredicates() throws {
        let plan = try MySQLChangePlanner.planUpdate(
            database: "sales.ops",
            table: "order`line",
            columnTypes: [
                "tenant_id": "bigint", "id": "int",
                "status": "varchar", "note": "text", "unchanged": "int",
            ],
            primaryKey: [("tenant_id", .number(7)), ("id", .string("order-1"))],
            original: [("status", .string("draft")), ("note", .null), ("unchanged", .number(4))],
            current: [("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4))])

        XCTAssertEqual(plan.text, [
            "UPDATE `sales.ops`.`order``line`",
            "SET `status` = ?,",
            "    `note` = ?",
            "WHERE `tenant_id` <=> ?",
            "  AND `id` <=> ?",
            "  AND BINARY `status` <=> BINARY ?",
            "  AND BINARY `note` <=> BINARY ?",
            "  AND `unchanged` <=> ?",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [
            .string("paid"), .string("ready"),
            .number(7), .string("order-1"),
            .string("draft"), .null, .number(4),
        ])
    }

    func testDeleteMatchesIdentityAndOriginalValues() throws {
        let plan = try MySQLChangePlanner.planDelete(
            database: "shop",
            table: "users",
            columnTypes: ["id": "int", "email": "varchar", "active": "tinyint"],
            primaryKey: [("id", .number(42))],
            original: [("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true))])

        XCTAssertEqual(plan.text, [
            "DELETE FROM `shop`.`users`",
            "WHERE `id` <=> ?",
            "  AND BINARY `email` <=> BINARY ?",
            "  AND `active` <=> ?",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.number(42), .string("before@example.test"), .bool(true)])
    }

    func testQuotesIdentifiersIndependentlyAndNeverInterpolatesValues() throws {
        let hostileValue = "x'); DROP TABLE audit; --"
        let plan = try MySQLChangePlanner.planUpdate(
            database: "shop",
            table: "users`; DROP TABLE audit; --",
            columnTypes: ["id": "int", "display_name": "varchar"],
            primaryKey: [("id", .number(1))],
            original: [("display_name", .string("before"))],
            current: [("display_name", .string(hostileValue))])

        XCTAssertEqual(try MySQLChangePlanner.quoteIdentifier("a.b`c"), "`a.b``c`")
        XCTAssertTrue(plan.text.contains("UPDATE `shop`.`users``; DROP TABLE audit; --`"))
        XCTAssertFalse(plan.text.contains(hostileValue))
        XCTAssertEqual(plan.values.first, .string(hostileValue))
    }

    func testRejectsMissingIdentityEmptyPatchesAndPrimaryKeyEdits() {
        assertPlanThrows(containing: "primary-key") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [],
                original: [("name", .string("before"))],
                current: [("name", .string("after"))])
        }
        assertPlanThrows(containing: "original values") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [],
                current: [])
        }
        assertPlanThrows(containing: "changed value") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("name", .string("same"))],
                current: [("name", .string("same"))])
        }
        assertPlanThrows(containing: "cannot be edited") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(1)), ("name", .string("before"))],
                current: [("id", .number(2)), ("name", .string("before"))])
        }
    }

    func testRejectsAmbiguousPatchesAndDangerousKeys() {
        assertPlanThrows(containing: "same columns") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("first_name", .string("before"))],
                current: [("display_name", .string("after"))])
        }
        assertPlanThrows(containing: "dangerous key") {
            try MySQLChangePlanner.planUpdate(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("__proto__", .string("value"))],
                current: [("__proto__", .string("value2"))])
        }
        assertPlanThrows(containing: "cannot be null") {
            try MySQLChangePlanner.planDelete(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .null)],
                original: [("id", .null)])
        }
        assertPlanThrows(containing: "inconsistent") {
            try MySQLChangePlanner.planDelete(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try MySQLChangePlanner.planDelete(
                database: "shop", table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("bad\u{0}name", .number(1))])
        }
    }

    func testQuoteIdentifierRejectsEmptyAndNUL() {
        XCTAssertThrowsError(try MySQLChangePlanner.quoteIdentifier(""))
        XCTAssertThrowsError(try MySQLChangePlanner.quoteIdentifier("a\u{0}b"))
    }

    // MARK: - Byte-level optimistic matching

    /// Every string-family type matches bytes through `BINARY`; the numeric,
    /// temporal, binary, and json families keep native `<=>` (fixed-scale
    /// decimal stores one canonical rendering per value, binary columns
    /// already compare bytes).
    func testStringFamilyColumnsUseBinaryEquality() throws {
        var columnTypes: [String: String] = ["id": "int"]
        for (index, type) in MySQLChangePlanner.byteComparedTypeNames.enumerated() {
            columnTypes["s\(index)"] = type
        }
        columnTypes["price"] = "decimal"
        columnTypes["moment"] = "datetime"
        columnTypes["payload"] = "blob"
        columnTypes["doc"] = "json"

        var original: [MySQLFieldEntry] = [("id", .number(1))]
        for index in 0..<MySQLChangePlanner.byteComparedTypeNames.count {
            original.append(("s\(index)", .string("v\(index)")))
        }
        original.append(("price", .string("1.1000")))
        original.append(("moment", .string("2024-02-29 01:02:03")))
        original.append(("payload", .binary(Data([0xDE, 0xAD]))))
        original.append(("doc", .string("{}")))

        let plan = try MySQLChangePlanner.planDelete(
            database: "shop", table: "users", columnTypes: columnTypes,
            primaryKey: [("id", .number(1))], original: original)

        for index in 0..<MySQLChangePlanner.byteComparedTypeNames.count {
            XCTAssertTrue(
                plan.text.contains("BINARY `s\(index)` <=> BINARY ?"),
                "\(columnTypes["s\(index)"]!) must compare bytes: \(plan.text)")
        }
        for column in ["price", "moment", "payload", "doc"] {
            XCTAssertTrue(
                plan.text.contains("AND `\(column)` <=> ?"),
                "\(column) must keep native comparison: \(plan.text)")
        }
    }

    /// The byte comparison is decided by column type, not by the snapshot
    /// value's shape: a NULL or a numeric-looking string under a collation-
    /// bearing column still matches bytes, and `<=>` stays NULL-safe.
    func testBinaryEqualityIsColumnDrivenAndNullSafe() throws {
        let plan = try MySQLChangePlanner.planUpdate(
            database: "shop", table: "users",
            columnTypes: ["code": "varchar", "note": "text", "rank": "int"],
            primaryKey: [("code", .string("ABC"))],
            original: [("code", .string("ABC")), ("note", .null), ("rank", .number(3))],
            current: [("code", .string("ABC")), ("note", .string("x")), ("rank", .number(3))])

        XCTAssertTrue(plan.text.contains("WHERE BINARY `code` <=> BINARY ?"))
        XCTAssertTrue(plan.text.contains("AND BINARY `note` <=> BINARY ?"))
        XCTAssertTrue(plan.text.contains("AND `rank` <=> ?"))
        // Bind order is unchanged: assignments, then key, then the rest.
        XCTAssertEqual(plan.values, [.string("x"), .string("ABC"), .null, .number(3)])
    }

    /// Columns missing from the type map keep native comparison rather than
    /// failing planning (the adapter always passes complete metadata).
    func testUnknownColumnTypeKeepsNativeEquality() throws {
        let plan = try MySQLChangePlanner.planDelete(
            database: "shop", table: "users", columnTypes: [:],
            primaryKey: [("id", .number(1))],
            original: [("id", .number(1)), ("note", .string("x"))])
        XCTAssertTrue(plan.text.contains("AND `note` <=> ?"))
    }

    // MARK: - Metadata validation

    func testChangeTableMetadataFoldsRowsAndOrdersPrimaryKey() throws {
        let metadata = try MySQLChangePlanner.changeTableMetadata(rows: [
            ("id", "int", 2),
            ("tenant_id", "bigint", 1),
            ("note", "text", 0),
        ])
        XCTAssertEqual(metadata.columns, ["id", "tenant_id", "note"])
        XCTAssertEqual(metadata.primaryKey, ["tenant_id", "id"])
        XCTAssertEqual(metadata.columnTypes["id"], "int")
        XCTAssertEqual(metadata.columnTypes["tenant_id"], "bigint")
    }

    func testChangeTableMetadataRejectsNonRoundTrippingTypes() {
        for dataType in ["bit", "geometry", "point", "polygon", "GEOMETRYCOLLECTION"] {
            XCTAssertThrowsError(
                try MySQLChangePlanner.changeTableMetadata(rows: [
                    ("id", "int", 1),
                    ("payload", dataType, 0),
                ]),
                "type \(dataType) must be rejected"
            ) { error in
                guard let planError = error as? MySQLChangePlanError else {
                    return XCTFail("Unexpected error \(error)")
                }
                XCTAssertTrue(planError.userMessage.contains("payload"), planError.userMessage)
                XCTAssertTrue(
                    planError.userMessage.contains(dataType.lowercased()), planError.userMessage)
            }
        }
        // json normalizes on write like PostgreSQL's jsonb, so it round-trips.
        XCTAssertNoThrow(try MySQLChangePlanner.changeTableMetadata(rows: [
            ("id", "int", 1),
            ("payload", "json", 0),
        ]))
    }

    func testChangeTableMetadataRejectsInvalidShape() {
        XCTAssertThrowsError(try MySQLChangePlanner.changeTableMetadata(rows: []))
        // No primary key.
        XCTAssertThrowsError(try MySQLChangePlanner.changeTableMetadata(rows: [
            ("note", "text", 0),
        ]))
        // Duplicate column.
        XCTAssertThrowsError(try MySQLChangePlanner.changeTableMetadata(rows: [
            ("id", "int", 1),
            ("id", "int", 0),
        ]))
        // Duplicate ordinal.
        XCTAssertThrowsError(try MySQLChangePlanner.changeTableMetadata(rows: [
            ("a", "int", 1),
            ("b", "int", 1),
        ]))
        // Non-contiguous ordinals.
        XCTAssertThrowsError(try MySQLChangePlanner.changeTableMetadata(rows: [
            ("a", "int", 1),
            ("b", "int", 3),
        ]))
    }
}
