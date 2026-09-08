import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// "Copy as INSERT" rendering matrix: lowest-common-denominator SQL with
/// double-quoted identifiers and single-quote-doubled strings; values without
/// a portable literal (binary, non-finite numbers) fail closed, matching the
/// existing export discipline.
final class InsertStatementRendererTests: XCTestCase {
    private func columns(_ names: [String]) -> [ColumnMeta] {
        names.map { ColumnMeta(name: $0, typeName: "text") }
    }

    private func render(
        table: [String] = ["users"], columns: [ColumnMeta], rows: [[DisplayValue]]
    ) throws -> String {
        try InsertStatementRenderer.render(table: table, columns: columns, rows: rows)
    }

    func testScalars() throws {
        let text = try render(
            columns: columns(["id", "name", "active", "note"]),
            rows: [
                [.number(1), .string("Ada"), .bool(true), .null],
                [.number(2), .string("Bob"), .bool(false), .string("x")],
            ])
        XCTAssertEqual(
            text,
            """
            INSERT INTO "users" ("id", "name", "active", "note") VALUES (1, 'Ada', TRUE, NULL);
            INSERT INTO "users" ("id", "name", "active", "note") VALUES (2, 'Bob', FALSE, 'x');
            """)
    }

    func testSingleQuoteDoubling() throws {
        let text = try render(
            columns: columns(["name"]),
            rows: [[.string("it's a 'quoted' ''name''")]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "users" ("name") VALUES ('it''s a ''quoted'' ''''name''''');"#)
    }

    /// Backslashes pass through unescaped (standard SQL); under MySQL's
    /// default sql_mode they may instead be read as escape introducers — the
    /// documented dialect trade-off in `InsertStatementRenderer`'s doc comment.
    func testBackslashesPassThrough() throws {
        let text = try render(
            columns: columns(["path"]),
            rows: [[.string(#"C:\tmp\a'b"#)]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "users" ("path") VALUES ('C:\tmp\a''b');"#)
    }

    func testIdentifierQuotingDoublesDoubleQuotes() throws {
        let text = try render(
            table: ["weird\"schema", "user\"s"],
            columns: [ColumnMeta(name: "a\"b", typeName: "int")],
            rows: [[.number(1)]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "weird""schema"."user""s" ("a""b") VALUES (1);"#)
    }

    /// Column order in the statement follows the result's column order.
    func testColumnOrderPreserved() throws {
        let text = try render(
            columns: columns(["z", "a", "m"]),
            rows: [[.number(1), .number(2), .number(3)]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "users" ("z", "a", "m") VALUES (1, 2, 3);"#)
    }

    func testNumbersRenderAsExactFiniteText() throws {
        let text = try render(
            columns: columns(["n"]),
            rows: [
                [.number(2.5)],
                [.number(-4)],
                [.number(9_007_199_254_740_991)],  // max safe integer: exact text
                // Precision-sensitive values cross as strings and stay strings.
                [.string("9007199254740993")],
            ])
        XCTAssertEqual(
            text,
            """
            INSERT INTO "users" ("n") VALUES (2.5);
            INSERT INTO "users" ("n") VALUES (-4);
            INSERT INTO "users" ("n") VALUES (9007199254740991);
            INSERT INTO "users" ("n") VALUES ('9007199254740993');
            """)
    }

    /// No portable SQL literal for non-finite numbers: fail closed.
    func testNonFiniteNumberThrows() {
        for value in [DisplayValue.number(.nan), .number(.infinity), .number(-.infinity)] {
            XCTAssertThrowsError(try render(columns: columns(["n"]), rows: [[value]])) { error in
                XCTAssertEqual(error as? ResultExportError, .unsupportedValue)
            }
        }
    }

    /// Binary has no portable SQL literal: fail closed.
    func testBinaryThrows() {
        XCTAssertThrowsError(
            try render(columns: columns(["blob"]), rows: [[.binary(Data([0xDE, 0xAD]))]])
        ) { error in
            XCTAssertEqual(error as? ResultExportError, .unsupportedValue)
        }
    }

    /// Nested values cross as a canonical-JSON string literal (sorted keys),
    /// the same shape CSV cells use.
    func testNestedValuesBecomeJSONStringLiteral() throws {
        let text = try render(
            columns: columns(["payload"]),
            rows: [[.object([("b", .number(2)), ("a", .array([.null, .string("s")]))])]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "users" ("payload") VALUES ('{"a":[null,"s"],"b":2}');"#)
    }

    /// Adapter-truncated values are part of the displayed result and cross
    /// verbatim with their marker, exactly like the CSV/JSONL exports.
    func testTruncatedMarkerPassesThrough() throws {
        let truncated = String(repeating: "x", count: 8) + "…[dbbbb truncated 8388608 bytes]"
        let text = try render(columns: columns(["body"]), rows: [[.string(truncated)]])
        XCTAssertEqual(
            text,
            #"INSERT INTO "users" ("body") VALUES ('xxxxxxxx…[dbbbb truncated 8388608 bytes]');"#)
    }

    func testRowShapeMismatchThrows() {
        XCTAssertThrowsError(
            try render(columns: columns(["a", "b"]), rows: [[.number(1)]])
        ) { error in
            XCTAssertEqual(error as? ResultExportError, .invalidShape)
        }
    }

    func testEmptyTablePathThrows() {
        XCTAssertThrowsError(
            try render(table: [], columns: columns(["a"]), rows: [[.number(1)]])
        ) { error in
            XCTAssertEqual(error as? ResultExportError, .invalidShape)
        }
    }

    func testEmptyRowsRenderNothing() throws {
        XCTAssertEqual(try render(columns: columns(["a"]), rows: []), "")
    }

    // MARK: - tableNameParts

    func testPostgresQualifiedNameFromObjectID() {
        let ref = PostgresObjectRef(kind: .table, schema: "app", name: "users")
        let object = DatabaseObject(
            id: PostgresObjectIDCodec.encode(ref), parentID: nil, name: "users", kind: .table)
        XCTAssertEqual(
            InsertStatementRenderer.tableNameParts(engine: .postgresql, object: object),
            ["app", "users"])
    }

    /// Demo-fixture ids do not decode; the bare name is the fallback.
    func testPostgresFallsBackToBareName() {
        let object = DatabaseObject(id: "pg.table.users", parentID: nil, name: "users", kind: .table)
        XCTAssertEqual(
            InsertStatementRenderer.tableNameParts(engine: .postgresql, object: object),
            ["users"])
    }

    func testMySQLQualifiedNameFromObjectID() {
        let ref = MySQLObjectRef(kind: .table, database: "app", name: "orders")
        let object = DatabaseObject(id: ref.id, parentID: nil, name: "orders", kind: .table)
        XCTAssertEqual(
            InsertStatementRenderer.tableNameParts(engine: .mysql, object: object),
            ["app", "orders"])
    }

    func testMySQLFallsBackToBareName() {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
        XCTAssertEqual(
            InsertStatementRenderer.tableNameParts(engine: .mysql, object: object),
            ["items"])
    }

    func testSQLiteUsesBareName() {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
        XCTAssertEqual(
            InsertStatementRenderer.tableNameParts(engine: .sqlite, object: object),
            ["items"])
    }
}
