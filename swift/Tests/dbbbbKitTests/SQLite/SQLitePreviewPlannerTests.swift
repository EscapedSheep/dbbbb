import XCTest
import GRDB
import dbbbbCore
@testable import dbbbbKit

final class SQLitePreviewPlannerTests: XCTestCase {
    private let object = DatabaseObject(id: "sqlite:x", parentID: nil, name: "notes", kind: .table)

    private func request(
        offset: Int = 0,
        limit: Int = 100,
        sort: PreviewRequest.Sort? = nil,
        filter: PreviewRequest.Filter? = nil,
        equalities: [PreviewRequest.Equality] = []
    ) -> PreviewRequest {
        PreviewRequest(object: object, offset: offset, limit: limit, sort: sort, filter: filter, equalities: equalities)
    }

    func testDefaultRequestIsFirstUnshapedPage() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request())
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "notes"
            LIMIT 101 OFFSET 0
            """)
        XCTAssertNil(plan.filterPattern)
        XCTAssertEqual(plan.limit, 100)
        XCTAssertEqual(plan.offset, 0)
    }

    func testPagingClauses() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(offset: 50, limit: 10))
        XCTAssertTrue(plan.sql.hasSuffix("LIMIT 11 OFFSET 50"))
    }

    func testSortAscendingAndDescending() throws {
        let asc = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            sort: PreviewRequest.Sort(column: "title", ascending: true)))
        XCTAssertTrue(asc.sql.contains(#"ORDER BY "title" ASC"#))
        let desc = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            sort: PreviewRequest.Sort(column: "title", ascending: false)))
        XCTAssertTrue(desc.sql.contains(#"ORDER BY "title" DESC"#))
    }

    /// SQLite's LIKE has no default escape character, so ESCAPE '\' is
    /// mandatory and the pattern crosses as the bound `?` argument.
    func testFilterIsCastLikeWithEscapeAndBoundPattern() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            filter: PreviewRequest.Filter(column: "body", contains: "hello")))
        XCTAssertTrue(plan.sql.contains(#"WHERE CAST("body" AS TEXT) LIKE ? ESCAPE '\'"#))
        XCTAssertEqual(plan.filterPattern, "%hello%")
        XCTAssertFalse(plan.sql.contains("hello"))
    }

    func testFilterEscapingMatrix() throws {
        let cases: [(input: String, pattern: String)] = [
            ("100%", #"%100\%%"#),
            ("a_b", #"%a\_b%"#),
            (#"back\slash"#, #"%back\\slash%"#),
            ("plain", "%plain%"),
        ]
        for (input, expected) in cases {
            let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
                filter: PreviewRequest.Filter(column: "c", contains: input)))
            XCTAssertEqual(plan.filterPattern, expected, "input: \(input)")
        }
    }

    /// Dangerous identifiers are quoted with the doubled-quote rule.
    func testDangerousIdentifiersAreQuoted() throws {
        let plan = try SQLitePreviewPlanner.plan(
            table: "ta\"ble",
            request: request(
                sort: PreviewRequest.Sort(column: "so\"rt", ascending: true),
                filter: PreviewRequest.Filter(column: "fi\"lter", contains: "x")))
        XCTAssertTrue(plan.sql.contains(#"FROM "ta""ble""#))
        XCTAssertTrue(plan.sql.contains(#"WHERE CAST("fi""lter" AS TEXT) LIKE ? ESCAPE '\'"#))
        XCTAssertTrue(plan.sql.contains(#"ORDER BY "so""rt" ASC"#))
    }

    func testInvalidIdentifierFailsClosed() {
        XCTAssertThrowsError(try SQLitePreviewPlanner.plan(table: "", request: request()))
        XCTAssertThrowsError(try SQLitePreviewPlanner.plan(table: "notes", request: request(
            sort: PreviewRequest.Sort(column: "", ascending: true))))
        XCTAssertThrowsError(try SQLitePreviewPlanner.plan(table: "notes", request: request(
            filter: PreviewRequest.Filter(column: "bad\0column", contains: "x"))))
    }

    /// The generated SQL must pass the read-only classifier.
    func testGeneratedSQLPassesReadOnlyClassifier() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            offset: 100,
            sort: PreviewRequest.Sort(column: "title", ascending: false),
            filter: PreviewRequest.Filter(column: "title", contains: "a%b")))
        XCTAssertNoThrow(try assertSQLiteReadOnlySQL(plan.sql))
    }

    // MARK: Equality predicates (ROADMAP M1 ⑤)

    /// Equality binds the value as a `?` argument; integral numbers bind as
    /// INTEGER so the column's stored storage class matches.
    func testEqualityIsBoundWithStorageClassPreserved() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "notes"
            WHERE "id" = ?
            LIMIT 101 OFFSET 0
            """)
        XCTAssertEqual(plan.equalityBinds, [Int64(42).databaseValue])
        XCTAssertNil(plan.filterPattern)
        XCTAssertFalse(plan.sql.contains("42"))
    }

    /// Non-integral numbers, strings, bools, and binary keep their storage
    /// classes through the change path's bind conversion.
    func testEqualityBindStorageClasses() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "t", request: request(
            equalities: [
                PreviewRequest.Equality(column: "r", value: .number(1.5)),
                PreviewRequest.Equality(column: "s", value: .string("x")),
                PreviewRequest.Equality(column: "b", value: .bool(true)),
                PreviewRequest.Equality(column: "blob", value: .binary(Data([1, 2]))),
            ]))
        XCTAssertEqual(plan.equalityBinds, [
            Double(1.5).databaseValue,
            "x".databaseValue,
            Int64(1).databaseValue,
            Data([1, 2]).databaseValue,
        ])
        XCTAssertEqual(plan.sql.components(separatedBy: " = ?").count - 1, 4)
    }

    /// A NULL equality renders as `IS NULL` and binds nothing.
    func testNullEqualityBindsNothing() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            equalities: [PreviewRequest.Equality(column: "deleted_at", value: .null)]))
        XCTAssertTrue(plan.sql.contains(#"WHERE "deleted_at" IS NULL"#))
        XCTAssertTrue(plan.equalityBinds.isEmpty)
    }

    /// Unbindable values (documents/arrays, non-finite numbers) fail closed
    /// at plan time.
    func testUnbindableEqualityFailsClosed() {
        XCTAssertThrowsError(try SQLitePreviewPlanner.plan(table: "t", request: request(
            equalities: [PreviewRequest.Equality(column: "c", value: .object(["a": .number(1)]))])))
        XCTAssertThrowsError(try SQLitePreviewPlanner.plan(table: "t", request: request(
            equalities: [PreviewRequest.Equality(column: "c", value: .number(.infinity))])))
    }

    /// Equality-filtered previews must also pass the read-only classifier.
    func testEqualitySQLPassesReadOnlyClassifier() throws {
        let plan = try SQLitePreviewPlanner.plan(table: "notes", request: request(
            filter: PreviewRequest.Filter(column: "body", contains: "a"),
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertTrue(plan.sql.contains(#"CAST("body" AS TEXT) LIKE ? ESCAPE '\'"#))
        XCTAssertTrue(plan.sql.contains(#"AND "id" = ?"#))
        XCTAssertNoThrow(try assertSQLiteReadOnlySQL(plan.sql))
    }
}
