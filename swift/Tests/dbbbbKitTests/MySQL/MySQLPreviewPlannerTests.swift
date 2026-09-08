import XCTest
import dbbbbCore
@testable import dbbbbKit

final class MySQLPreviewPlannerTests: XCTestCase {
    private let object = DatabaseObject(id: "mysql:x", parentID: nil, name: "users", kind: .table)

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
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request())
        XCTAssertEqual(plan.text, """
            SELECT *
            FROM `shop`.`users`
            LIMIT 101 OFFSET 0
            """)
        XCTAssertNil(plan.filterPattern)
        XCTAssertEqual(plan.limit, 100)
        XCTAssertEqual(plan.offset, 0)
    }

    func testPagingClauses() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(offset: 200, limit: 25))
        XCTAssertTrue(plan.text.hasSuffix("LIMIT 26 OFFSET 200"))
    }

    func testSortAscendingAndDescending() throws {
        let asc = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "email", ascending: true)))
        XCTAssertTrue(asc.text.contains("ORDER BY `email` ASC"))
        let desc = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "total", ascending: false)))
        XCTAssertTrue(desc.text.contains("ORDER BY `total` DESC"))
    }

    /// The filter value is bound through the session variable; the SQL text
    /// contains neither the value nor a `?` placeholder.
    func testFilterIsCastLikeWithSessionVariable() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            filter: PreviewRequest.Filter(column: "email", contains: "alice")))
        XCTAssertTrue(plan.text.contains("WHERE CAST(`email` AS CHAR) LIKE @dbbbb_preview_filter"))
        XCTAssertEqual(plan.filterPattern, "%alice%")
        XCTAssertFalse(plan.text.contains("alice"))
        XCTAssertFalse(plan.text.contains("?"))
        XCTAssertEqual(MySQLPreviewPlanner.bindFilterStatement, "SET @dbbbb_preview_filter = ?")
    }

    func testFilterEscapingMatrix() throws {
        let cases: [(input: String, pattern: String)] = [
            ("100%", #"100\%"#.wrapped),
            ("a_b", #"a\_b"#.wrapped),
            (#"back\slash"#, #"back\\slash"#.wrapped),
            ("plain", "plain".wrapped),
        ]
        for (input, expected) in cases {
            let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
                filter: PreviewRequest.Filter(column: "c", contains: input)))
            XCTAssertEqual(plan.filterPattern, expected, "input: \(input)")
        }
    }

    /// Backtick quoting doubles embedded backticks, in every position.
    func testDangerousIdentifiersAreQuoted() throws {
        let plan = try MySQLPreviewPlanner.plan(
            database: "we`ird", table: "ta`ble",
            request: request(
                sort: PreviewRequest.Sort(column: "so`rt", ascending: true),
                filter: PreviewRequest.Filter(column: "fi`lter", contains: "x")))
        XCTAssertTrue(plan.text.contains("FROM `we``ird`.`ta``ble`"))
        XCTAssertTrue(plan.text.contains("WHERE CAST(`fi``lter` AS CHAR) LIKE @dbbbb_preview_filter"))
        XCTAssertTrue(plan.text.contains("ORDER BY `so``rt` ASC"))
    }

    func testEmptyIdentifierFailsClosed() {
        XCTAssertThrowsError(try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "", ascending: true))))
        XCTAssertThrowsError(try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            filter: PreviewRequest.Filter(column: "bad\0column", contains: "x"))))
    }

    func testFilterAndSortComposeInOrder() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "d", table: "t", request: request(
            offset: 100,
            sort: PreviewRequest.Sort(column: "c", ascending: false),
            filter: PreviewRequest.Filter(column: "c", contains: "v")))
        XCTAssertEqual(plan.text, """
            SELECT *
            FROM `d`.`t`
            WHERE CAST(`c` AS CHAR) LIKE @dbbbb_preview_filter
            ORDER BY `c` DESC
            LIMIT 101 OFFSET 100
            """)
        XCTAssertEqual(plan.filterPattern, "%v%")
    }

    /// The generated SQL must pass the read-only classifier.
    func testGeneratedSQLPassesReadOnlyClassifier() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            offset: 100,
            sort: PreviewRequest.Sort(column: "email", ascending: false),
            filter: PreviewRequest.Filter(column: "email", contains: "a%b")))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly(plan.text))
    }

    // MARK: Equality predicates (ROADMAP M1 ⑤)

    /// Equality uses MySQL's null-safe `<=>` against a session variable; the
    /// value crosses only through the bind statement, never the SQL text.
    func testEqualityIsNullSafeAndBoundViaSessionVariable() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertEqual(plan.text, """
            SELECT *
            FROM `shop`.`users`
            WHERE `id` <=> @dbbbb_preview_eq_0
            LIMIT 101 OFFSET 0
            """)
        XCTAssertEqual(plan.equalityValues, [.number(42)])
        XCTAssertEqual(plan.bindEqualitiesStatement, "SET @dbbbb_preview_eq_0 = ?")
        XCTAssertNil(plan.filterPattern)
        XCTAssertFalse(plan.text.contains("42"))
    }

    /// A NULL equality renders as `IS NULL` and produces no bind statement.
    func testNullEqualityBindsNothing() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "deleted_at", value: .null)]))
        XCTAssertTrue(plan.text.contains("WHERE `deleted_at` IS NULL"))
        XCTAssertTrue(plan.equalityValues.isEmpty)
        XCTAssertNil(plan.bindEqualitiesStatement)
    }

    /// Non-NULL equalities number their variables from zero; NULLs in between
    /// leave no gaps in the bind statement.
    func testMultipleEqualitiesComposeAndBindInOrder() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "t", request: request(
            filter: PreviewRequest.Filter(column: "name", contains: "a"),
            equalities: [
                PreviewRequest.Equality(column: "org_id", value: .number(7)),
                PreviewRequest.Equality(column: "note", value: .null),
                PreviewRequest.Equality(column: "code", value: .string("X")),
            ]))
        XCTAssertEqual(plan.text, """
            SELECT *
            FROM `shop`.`t`
            WHERE CAST(`name` AS CHAR) LIKE @dbbbb_preview_filter
              AND `org_id` <=> @dbbbb_preview_eq_0
              AND `note` IS NULL
              AND `code` <=> @dbbbb_preview_eq_1
            LIMIT 101 OFFSET 0
            """)
        XCTAssertEqual(plan.filterPattern, "%a%")
        XCTAssertEqual(plan.equalityValues, [.number(7), .string("X")])
        XCTAssertEqual(
            plan.bindEqualitiesStatement,
            "SET @dbbbb_preview_eq_0 = ?, @dbbbb_preview_eq_1 = ?")
    }

    func testEqualityIdentifierIsQuoted() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "we`ird", value: .string("v"))]))
        XCTAssertTrue(plan.text.contains("`we``ird` <=> @dbbbb_preview_eq_0"))
        XCTAssertFalse(plan.text.contains("'v'"))
        XCTAssertThrowsError(try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "bad\0column", value: .number(1))])))
    }

    /// Equality-filtered previews must also pass the read-only classifier.
    func testEqualitySQLPassesReadOnlyClassifier() throws {
        let plan = try MySQLPreviewPlanner.plan(database: "shop", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly(plan.text))
    }
}

private extension String {
    var wrapped: String { "%\(self)%" }
}
