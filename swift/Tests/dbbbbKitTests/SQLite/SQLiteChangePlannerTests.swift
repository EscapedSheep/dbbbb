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
            columnTypes: [
                "tenant_id": "BIGINT", "id": "INTEGER",
                "status": "TEXT", "note": "VARCHAR(20)", "unchanged": "INTEGER",
            ],
            primaryKey: [("tenant_id", .number(7)), ("id", .string("order-1"))],
            original: [("status", .string("draft")), ("note", .null), ("unchanged", .number(4))],
            current: [("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4))])

        XCTAssertEqual(plan.text, [
            "UPDATE \"order\"\"line\"",
            "SET \"status\" = ?,",
            "    \"note\" = ?",
            "WHERE \"tenant_id\" IS ?",
            "  AND \"id\" IS ?",
            "  AND \"status\" IS ? COLLATE BINARY",
            "  AND \"note\" IS ? COLLATE BINARY",
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
            columnTypes: ["id": "INTEGER", "email": "TEXT", "active": "BOOLEAN"],
            primaryKey: [("id", .number(42))],
            original: [("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true))])

        XCTAssertEqual(plan.text, [
            "DELETE FROM \"users\"",
            "WHERE \"id\" IS ?",
            "  AND \"email\" IS ? COLLATE BINARY",
            "  AND \"active\" IS ?",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.number(42), .string("before@example.test"), .bool(true)])
    }

    func testQuotesIdentifiersAndNeverInterpolatesValues() throws {
        let hostileValue = "x'); DROP TABLE audit; --"
        let plan = try SQLiteChangePlanner.planUpdate(
            table: "users\"; DROP TABLE audit; --",
            columnTypes: ["id": "INTEGER", "display_name": "TEXT"],
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
                table: "users", columnTypes: [:],
                primaryKey: [],
                original: [("name", .string("before"))],
                current: [("name", .string("after"))])
        }
        assertPlanThrows(containing: "original values") {
            try SQLiteChangePlanner.planUpdate(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [],
                current: [])
        }
        assertPlanThrows(containing: "changed value") {
            try SQLiteChangePlanner.planUpdate(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("name", .string("same"))],
                current: [("name", .string("same"))])
        }
        assertPlanThrows(containing: "cannot be edited") {
            try SQLiteChangePlanner.planUpdate(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(1)), ("name", .string("before"))],
                current: [("id", .number(2)), ("name", .string("before"))])
        }
    }

    func testRejectsAmbiguousPatchesAndDangerousKeys() {
        assertPlanThrows(containing: "same columns") {
            try SQLiteChangePlanner.planUpdate(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("first_name", .string("before"))],
                current: [("display_name", .string("after"))])
        }
        assertPlanThrows(containing: "dangerous key") {
            try SQLiteChangePlanner.planUpdate(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("__proto__", .string("value"))],
                current: [("__proto__", .string("value2"))])
        }
        assertPlanThrows(containing: "cannot be null") {
            try SQLiteChangePlanner.planDelete(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .null)],
                original: [("id", .null)])
        }
        assertPlanThrows(containing: "inconsistent") {
            try SQLiteChangePlanner.planDelete(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try SQLiteChangePlanner.planDelete(
                table: "users", columnTypes: [:],
                primaryKey: [("id", .number(1))],
                original: [("bad\u{0}name", .number(1))])
        }
    }

    func testQuoteIdentifierRejectsEmptyAndNUL() {
        XCTAssertThrowsError(try SQLiteChangePlanner.quoteIdentifier(""))
        XCTAssertThrowsError(try SQLiteChangePlanner.quoteIdentifier("a\u{0}b"))
    }

    // MARK: - Byte-level optimistic matching

    /// TEXT-affinity declared types compare bytes via `COLLATE BINARY` on the
    /// bound value; other affinities already compare storage classes exactly.
    /// Affinity follows SQLite's documented rules (INT wins over CHAR).
    func testTextAffinityColumnsUseCollationBinary() throws {
        let plan = try SQLiteChangePlanner.planDelete(
            table: "users",
            columnTypes: [
                "id": "INTEGER",
                "name": "TEXT", "nick": "VARCHAR(20)", "blob_text": "CLOB",
                "weird": "POINT",  // contains INT → INTEGER affinity
                "score": "REAL", "flag": "BOOLEAN",  // NUMERIC affinity
                "payload": "BLOB", "raw": "",
            ],
            primaryKey: [("id", .number(1))],
            original: [
                ("id", .number(1)),
                ("name", .string("n")), ("nick", .string("k")), ("blob_text", .string("c")),
                ("weird", .number(2)), ("score", .number(1.5)), ("flag", .bool(true)),
                ("payload", .binary(Data([0xDE]))), ("raw", .string("r")),
            ])

        for column in ["name", "nick", "blob_text"] {
            XCTAssertTrue(
                plan.text.contains("AND \"\(column)\" IS ? COLLATE BINARY"),
                "\(column) must compare bytes: \(plan.text)")
        }
        for column in ["weird", "score", "flag", "payload", "raw"] {
            XCTAssertTrue(
                plan.text.contains("AND \"\(column)\" IS ?\n")
                    || plan.text.contains("AND \"\(column)\" IS ?"),
                "\(column) must keep native comparison: \(plan.text)")
            XCTAssertFalse(
                plan.text.contains("\"\(column)\" IS ? COLLATE BINARY"),
                "\(column) must not be byte-compared: \(plan.text)")
        }
    }

    /// Byte comparison is decided by column affinity: NULL values and
    /// primary-key columns under TEXT affinity still compare bytes, `IS`
    /// stays NULL-safe, and bind order is unchanged.
    func testCollationBinaryIsColumnDrivenAndNullSafe() throws {
        let plan = try SQLiteChangePlanner.planUpdate(
            table: "users",
            columnTypes: ["code": "TEXT COLLATE NOCASE", "note": "TEXT", "rank": "INTEGER"],
            primaryKey: [("code", .string("ABC"))],
            original: [("code", .string("ABC")), ("note", .null), ("rank", .number(3))],
            current: [("code", .string("ABC")), ("note", .string("x")), ("rank", .number(3))])

        XCTAssertTrue(plan.text.contains("WHERE \"code\" IS ? COLLATE BINARY"))
        XCTAssertTrue(plan.text.contains("AND \"note\" IS ? COLLATE BINARY"))
        XCTAssertTrue(plan.text.contains("AND \"rank\" IS ?"))
        XCTAssertEqual(plan.values, [.string("x"), .string("ABC"), .null, .number(3)])
    }

    /// Columns missing from the type map keep native comparison rather than
    /// failing planning (the adapter always passes complete metadata).
    func testUnknownColumnTypeKeepsNativeEquality() throws {
        let plan = try SQLiteChangePlanner.planDelete(
            table: "users", columnTypes: [:],
            primaryKey: [("id", .number(1))],
            original: [("id", .number(1)), ("note", .string("x"))])
        XCTAssertTrue(plan.text.contains("AND \"note\" IS ?"))
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

    // MARK: - planInsert

    func testInsertIsParameterizedInEntryOrder() throws {
        let plan = try SQLiteChangePlanner.planInsert(
            table: "order\"line",
            entries: [("status", .string("draft")), ("note", .null), ("qty", .number(4))])

        XCTAssertEqual(plan.text, [
            "INSERT INTO \"order\"\"line\" (\"status\", \"note\", \"qty\")",
            "VALUES (?, ?, ?)",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.string("draft"), .null, .number(4)])
    }

    func testInsertWithNoEntriesUsesDefaultValues() throws {
        let plan = try SQLiteChangePlanner.planInsert(table: "t", entries: [])
        XCTAssertEqual(plan.text, "INSERT INTO \"t\" DEFAULT VALUES")
        XCTAssertEqual(plan.values, [])
    }

    func testInsertRejectsDangerousDuplicateAndInvalidFieldNames() {
        assertPlanThrows(containing: "dangerous key") {
            try SQLiteChangePlanner.planInsert(
                table: "t", entries: [("__proto__", .number(1))])
        }
        assertPlanThrows(containing: "duplicate field name") {
            try SQLiteChangePlanner.planInsert(
                table: "t", entries: [("a", .number(1)), ("a", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try SQLiteChangePlanner.planInsert(
                table: "t", entries: [("a\0b", .number(1))])
        }
    }

    /// Insert values are catalog-ordered and unknown columns rejected by the
    /// same mapper as edits — generated/hidden columns (excluded from the
    /// metadata) can never be targeted.
    func testInsertValuesReuseTheEditMappingRules() throws {
        let metadata = try SQLiteChangePlanner.changeTableMetadata(rows: [
            ("id", "INTEGER", 1),
            ("note", "TEXT", 0),
        ])
        let entries = try SQLiteChangeMapper.orderedEntries(
            ["note": .string("x"), "id": .number(7)],
            metadata: metadata,
            label: "SQLite insert values")
        XCTAssertEqual(entries.map(\.column), ["id", "note"])

        XCTAssertThrowsError(try SQLiteChangeMapper.orderedEntries(
            ["generated_col": .number(1)],
            metadata: metadata,
            label: "SQLite insert values"
        ))
    }
}
