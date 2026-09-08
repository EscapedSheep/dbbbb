import XCTest
import dbbbbCore
@testable import dbbbbKit

final class PostgresPreviewPlannerTests: XCTestCase {
    private let object = DatabaseObject(id: "pg:x", parentID: nil, name: "users", kind: .table)

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
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request())
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "public"."users"
            LIMIT 101 OFFSET 0;
            """)
        XCTAssertNil(plan.filterPattern)
        XCTAssertEqual(plan.limit, 100)
        XCTAssertEqual(plan.offset, 0)
    }

    func testPagingClauses() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(offset: 300, limit: 50))
        XCTAssertTrue(plan.sql.hasSuffix("LIMIT 51 OFFSET 300;"))
        XCTAssertEqual(plan.limit, 50)
        XCTAssertEqual(plan.offset, 300)
    }

    func testNegativeOffsetAndZeroLimitAreClamped() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(offset: -5, limit: 0))
        XCTAssertTrue(plan.sql.hasSuffix("LIMIT 2 OFFSET 0;"))
    }

    func testSortAscendingAndDescending() throws {
        let asc = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "email", ascending: true)))
        XCTAssertTrue(asc.sql.contains(#"ORDER BY "email" ASC"#))
        let desc = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "balance", ascending: false)))
        XCTAssertTrue(desc.sql.contains(#"ORDER BY "balance" DESC"#))
    }

    func testFilterIsCastLikeWithBoundPattern() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            filter: PreviewRequest.Filter(column: "email", contains: "alice")))
        XCTAssertTrue(plan.sql.contains(#"WHERE "email"::text LIKE $1 ESCAPE '\'"#))
        XCTAssertEqual(plan.filterPattern, "%alice%")
        // The raw filter text never appears in the SQL.
        XCTAssertFalse(plan.sql.contains("alice"))
    }

    /// LIKE wildcards and the escape character itself are escaped client-side
    /// before the value is wrapped in %…% and bound.
    func testFilterEscapingMatrix() throws {
        let cases: [(input: String, pattern: String)] = [
            ("100%", #"%100\%%"#),
            ("a_b", #"%a\_b%"#),
            (#"back\slash"#, #"%back\\slash%"#),
            (#"%\_"#, #"%\%\\\_%"#),
            ("plain", "%plain%"),
            ("", "%%"),
        ]
        for (input, expected) in cases {
            let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
                filter: PreviewRequest.Filter(column: "c", contains: input)))
            XCTAssertEqual(plan.filterPattern, expected, "input: \(input)")
        }
    }

    /// Dangerous identifiers are quoted with the doubled-quote rule, in every
    /// position they can appear.
    func testDangerousIdentifiersAreQuoted() throws {
        let plan = try PostgresPreviewPlanner.plan(
            schema: "we\"ird", table: "ta\"ble",
            request: request(
                sort: PreviewRequest.Sort(column: "so\"rt", ascending: true),
                filter: PreviewRequest.Filter(column: "fi\"lter", contains: "x")))
        XCTAssertTrue(plan.sql.contains(#"FROM "we""ird"."ta""ble""#))
        XCTAssertTrue(plan.sql.contains(#"WHERE "fi""lter"::text LIKE $1 ESCAPE '\'"#))
        XCTAssertTrue(plan.sql.contains(#"ORDER BY "so""rt" ASC"#))
        XCTAssertFalse(plan.sql.contains("x%"))
    }

    func testEmptyIdentifierFailsClosed() {
        XCTAssertThrowsError(try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            sort: PreviewRequest.Sort(column: "", ascending: true))))
        XCTAssertThrowsError(try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            filter: PreviewRequest.Filter(column: "bad\0column", contains: "x"))))
    }

    func testFilterAndSortComposeInOrder() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "s", table: "t", request: request(
            offset: 100,
            sort: PreviewRequest.Sort(column: "c", ascending: false),
            filter: PreviewRequest.Filter(column: "c", contains: "v")))
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "s"."t"
            WHERE "c"::text LIKE $1 ESCAPE '\\'
            ORDER BY "c" DESC
            LIMIT 101 OFFSET 100;
            """)
        XCTAssertEqual(plan.filterPattern, "%v%")
    }

    /// The generated SQL must pass the read-only classifier (preview is a
    /// read path on read-only profiles too).
    func testGeneratedSQLPassesReadOnlyClassifier() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            offset: 200,
            sort: PreviewRequest.Sort(column: "email", ascending: false),
            filter: PreviewRequest.Filter(column: "email", contains: "a%b")))
        XCTAssertNoThrow(try PostgresReadOnlyClassifier.assertReadOnly(plan.sql))
    }

    // MARK: Equality predicates (ROADMAP M1 ⑤)

    /// Equality uses the change planner's null-safe operator; values are
    /// never interpolated — the SQL shows only placeholders.
    func testEqualityIsNullSafeAndBound() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "public"."users"
            WHERE "id" IS NOT DISTINCT FROM $1
            LIMIT 101 OFFSET 0;
            """)
        XCTAssertEqual(plan.equalityValues, [.number(42)])
        XCTAssertNil(plan.filterPattern)
        XCTAssertFalse(plan.sql.contains("42"))
    }

    /// A NULL equality renders as `IS NULL` and binds nothing.
    func testNullEqualityBindsNothing() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "deleted_at", value: .null)]))
        XCTAssertTrue(plan.sql.contains(#"WHERE "deleted_at" IS NULL"#))
        XCTAssertTrue(plan.equalityValues.isEmpty)
    }

    /// The grid filter keeps `$1`; equality placeholders follow it, and the
    /// bind order is pattern-then-equalities.
    func testFilterAndEqualitiesComposeInPlaceholderOrder() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "s", table: "t", request: request(
            filter: PreviewRequest.Filter(column: "name", contains: "a"),
            equalities: [
                PreviewRequest.Equality(column: "org_id", value: .number(7)),
                PreviewRequest.Equality(column: "code", value: .string("X")),
                PreviewRequest.Equality(column: "note", value: .null),
            ]))
        XCTAssertEqual(plan.sql, """
            SELECT *
            FROM "s"."t"
            WHERE "name"::text LIKE $1 ESCAPE '\\'
              AND "org_id" IS NOT DISTINCT FROM $2
              AND "code" IS NOT DISTINCT FROM $3
              AND "note" IS NULL
            LIMIT 101 OFFSET 0;
            """)
        XCTAssertEqual(plan.filterPattern, "%a%")
        XCTAssertEqual(plan.equalityValues, [.number(7), .string("X")])
    }

    func testEqualityIdentifierIsQuoted() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "we\"ird", value: .string("v"))]))
        XCTAssertTrue(plan.sql.contains(#""we""ird" IS NOT DISTINCT FROM $1"#))
        XCTAssertFalse(plan.sql.contains("'v'"))
        XCTAssertThrowsError(try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "bad\0column", value: .number(1))])))
    }

    /// Equality-filtered previews must also pass the read-only classifier.
    func testEqualitySQLPassesReadOnlyClassifier() throws {
        let plan = try PostgresPreviewPlanner.plan(schema: "public", table: "users", request: request(
            equalities: [PreviewRequest.Equality(column: "id", value: .number(42))]))
        XCTAssertNoThrow(try PostgresReadOnlyClassifier.assertReadOnly(plan.sql))
    }
}
