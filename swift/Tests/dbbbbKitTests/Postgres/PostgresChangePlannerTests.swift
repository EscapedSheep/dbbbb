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
            columnTypeOIDs: [
                "tenant_id": 20, "id": 23,
                "status": 25, "note": 1043, "unchanged": 23,
            ],
            primaryKey: [("tenant_id", .number(7)), ("id", .string("order-1"))],
            original: [("status", .string("draft")), ("note", .null), ("unchanged", .number(4))],
            current: [("status", .string("paid")), ("note", .string("ready")), ("unchanged", .number(4))])

        XCTAssertEqual(plan.text, [
            "UPDATE \"sales.ops\".\"order\"\"line\"",
            "SET \"status\" = $1,",
            "    \"note\" = $2",
            "WHERE \"tenant_id\" IS NOT DISTINCT FROM $3",
            "  AND \"id\" IS NOT DISTINCT FROM $4",
            "  AND convert_to(\"status\"::text, 'UTF8')"
                + " IS NOT DISTINCT FROM convert_to($5::text, 'UTF8')",
            "  AND convert_to(\"note\"::text, 'UTF8')"
                + " IS NOT DISTINCT FROM convert_to($6::text, 'UTF8')",
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
            columnTypeOIDs: ["id": 23, "email": 1043, "active": 16],
            primaryKey: [("id", .number(42))],
            original: [("id", .number(42)), ("email", .string("before@example.test")), ("active", .bool(true))])

        XCTAssertEqual(plan.text, [
            "DELETE FROM \"public\".\"users\"",
            "WHERE \"id\" IS NOT DISTINCT FROM $1",
            "  AND convert_to(\"email\"::text, 'UTF8')"
                + " IS NOT DISTINCT FROM convert_to($2::text, 'UTF8')",
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
            columnTypeOIDs: ["id": 23, "display_name": 25],
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
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [],
                original: [("name", .string("before"))],
                current: [("name", .string("after"))])
        }
        assertPlanThrows(containing: "original values") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [],
                current: [])
        }
        assertPlanThrows(containing: "changed value") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("name", .string("same"))],
                current: [("name", .string("same"))])
        }
        assertPlanThrows(containing: "cannot be edited") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(1)), ("name", .string("before"))],
                current: [("id", .number(2)), ("name", .string("before"))])
        }
    }

    func testRejectsAmbiguousPatchesAndDangerousKeys() {
        assertPlanThrows(containing: "same columns") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("first_name", .string("before"))],
                current: [("display_name", .string("after"))])
        }
        assertPlanThrows(containing: "dangerous key") {
            try PostgresChangePlanner.planUpdate(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("__proto__", .string("value"))],
                current: [("__proto__", .string("value2"))])
        }
        assertPlanThrows(containing: "cannot be null") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .null)],
                original: [("id", .null)])
        }
        assertPlanThrows(containing: "inconsistent") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("id", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try PostgresChangePlanner.planDelete(
                schema: "public", table: "users", columnTypeOIDs: [:],
                primaryKey: [("id", .number(1))],
                original: [("bad\u{0}name", .number(1))])
        }
    }

    func testQuoteIdentifierRejectsEmptyAndNUL() {
        XCTAssertThrowsError(try PostgresChangePlanner.quoteIdentifier(""))
        XCTAssertThrowsError(try PostgresChangePlanner.quoteIdentifier("a\u{0}b"))
    }

    // MARK: - Byte-level optimistic matching

    /// Text-family and numeric columns compare their canonical UTF-8 text
    /// byte-for-byte (nondeterministic collations equate case variants;
    /// numeric value equality ignores display scale). Other types keep
    /// native `IS NOT DISTINCT FROM`.
    func testByteComparedTypeOIDsUseTextByteEquality() throws {
        let plan = try PostgresChangePlanner.planDelete(
            schema: "public", table: "users",
            columnTypeOIDs: [
                "id": 23,
                "name_col": 19, "body": 25, "code": 1042, "nick": 1043,
                "price": 1700,
                "big": 20, "payload": 17, "tags": 1009, "doc": 3802,
                "moment": 1114,
            ],
            primaryKey: [("id", .number(1))],
            original: [
                ("id", .number(1)),
                ("name_col", .string("n")), ("body", .string("b")),
                ("code", .string("c")), ("nick", .string("k")),
                ("price", .string("1.1000")),
                ("big", .string("9007199254740993")), ("payload", .binary(Data([0xDE]))),
                ("tags", .array([.string("a")])), ("doc", .string("{}")),
                ("moment", .string("2024-02-29 01:02:03")),
            ])

        for column in ["name_col", "body", "code", "nick", "price"] {
            XCTAssertTrue(
                plan.text.contains(
                    "convert_to(\"\(column)\"::text, 'UTF8')"
                        + " IS NOT DISTINCT FROM convert_to("),
                "\(column) must compare bytes: \(plan.text)")
        }
        for column in ["big", "payload", "tags", "doc", "moment"] {
            XCTAssertTrue(
                plan.text.contains("AND \"\(column)\" IS NOT DISTINCT FROM $"),
                "\(column) must keep native comparison: \(plan.text)")
        }
    }

    /// Byte comparison is decided by column type: a NULL or numeric-looking
    /// string under a text/numeric column still compares bytes, `IS NOT
    /// DISTINCT FROM` keeps its NULL semantics, and bind order is unchanged.
    func testByteEqualityIsColumnDrivenAndNullSafe() throws {
        let plan = try PostgresChangePlanner.planUpdate(
            schema: "public", table: "users",
            columnTypeOIDs: ["code": 1043, "note": 25, "price": 1700, "rank": 23],
            primaryKey: [("code", .string("ABC"))],
            original: [
                ("code", .string("ABC")), ("note", .null),
                ("price", .string("1.10")), ("rank", .number(3)),
            ],
            current: [
                ("code", .string("ABC")), ("note", .string("x")),
                ("price", .string("1.10")), ("rank", .number(3)),
            ])

        XCTAssertTrue(plan.text.contains(
            "WHERE convert_to(\"code\"::text, 'UTF8')"
                + " IS NOT DISTINCT FROM convert_to($2::text, 'UTF8')"))
        XCTAssertTrue(plan.text.contains("convert_to(\"note\"::text, 'UTF8')"))
        XCTAssertTrue(plan.text.contains("convert_to(\"price\"::text, 'UTF8')"))
        XCTAssertTrue(plan.text.contains("AND \"rank\" IS NOT DISTINCT FROM $5"))
        XCTAssertEqual(plan.values, [.string("x"), .string("ABC"), .null, .string("1.10"), .number(3)])
    }

    /// Columns missing from the OID map keep native comparison rather than
    /// failing planning (the adapter always passes complete metadata).
    func testUnknownColumnTypeKeepsNativeEquality() throws {
        let plan = try PostgresChangePlanner.planDelete(
            schema: "public", table: "users", columnTypeOIDs: [:],
            primaryKey: [("id", .number(1))],
            original: [("id", .number(1)), ("note", .string("x"))])
        XCTAssertTrue(plan.text.contains("AND \"note\" IS NOT DISTINCT FROM $2"))
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

    /// Generated and identity columns are filtered out of the change metadata
    /// (same as the MySQL/SQLite engines), so a table containing them is
    /// refused wholesale: the previewed record carries the column, the editable
    /// metadata does not, and the mapping fails closed.
    func testGeneratedAndIdentityColumnsAreExcludedFromChangeMetadata() throws {
        let sql = PostgresChangePlanner.listTableChangeColumnsSQL
        XCTAssertTrue(sql.contains("AND a.attgenerated = ''"))
        XCTAssertTrue(sql.contains("AND a.attidentity = ''"))

        let metadata = try PostgresChangePlanner.changeTableMetadata(rows: [
            ("id", 23, "int4", 1),
            ("note", 25, "text", 0),
        ])
        XCTAssertThrowsError(try PostgresChangeMapper.orderedEntries(
            ["id": .number(1), "note": .string("x"), "computed": .string("x")],
            metadata: metadata,
            label: "PostgreSQL original values"
        ))
    }

    // MARK: - planInsert

    func testInsertIsParameterizedInEntryOrderWithReturning() throws {
        let plan = try PostgresChangePlanner.planInsert(
            schema: "odd\"schema",
            table: "user\"table",
            entries: [("name", .string("ado\"le")), ("score", .number(9.5)), ("note", .null)])

        XCTAssertEqual(plan.text, [
            "INSERT INTO \"odd\"\"schema\".\"user\"\"table\" (\"name\", \"score\", \"note\")",
            "VALUES ($1, $2, $3)",
            "RETURNING *;",
        ].joined(separator: "\n"))
        XCTAssertEqual(plan.values, [.string("ado\"le"), .number(9.5), .null])
    }

    func testInsertWithNoEntriesUsesDefaultValues() throws {
        let plan = try PostgresChangePlanner.planInsert(schema: "public", table: "t", entries: [])
        XCTAssertEqual(plan.text, "INSERT INTO \"public\".\"t\" DEFAULT VALUES\nRETURNING *;")
        XCTAssertEqual(plan.values, [])
    }

    func testInsertRejectsDangerousDuplicateAndInvalidFieldNames() {
        assertPlanThrows(containing: "dangerous key") {
            try PostgresChangePlanner.planInsert(
                schema: "public", table: "t", entries: [("__proto__", .number(1))])
        }
        assertPlanThrows(containing: "duplicate field name") {
            try PostgresChangePlanner.planInsert(
                schema: "public", table: "t",
                entries: [("a", .number(1)), ("a", .number(2))])
        }
        assertPlanThrows(containing: "invalid field name") {
            try PostgresChangePlanner.planInsert(
                schema: "public", table: "t", entries: [("a\0b", .number(1))])
        }
    }

    /// Insert values are catalog-ordered and unknown columns rejected by the
    /// same mapper as edits — generated columns (excluded from the metadata)
    /// can never be targeted.
    func testInsertValuesReuseTheEditMappingRules() throws {
        let metadata = try PostgresChangePlanner.changeTableMetadata(rows: [
            ("id", 23, "int4", 1),
            ("note", 25, "text", 0),
        ])
        let entries = try PostgresChangeMapper.orderedEntries(
            ["note": .string("x"), "id": .number(7)],
            metadata: metadata,
            label: "PostgreSQL insert values")
        XCTAssertEqual(entries.map(\.column), ["id", "note"])

        XCTAssertThrowsError(try PostgresChangeMapper.orderedEntries(
            ["generated_col": .number(1)],
            metadata: metadata,
            label: "PostgreSQL insert values"
        ))
    }
}
