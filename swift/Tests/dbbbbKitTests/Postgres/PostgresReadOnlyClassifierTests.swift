import XCTest
@testable import dbbbbKit

final class PostgresReadOnlyClassifierTests: XCTestCase {
    private func assertAllowed(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try PostgresReadOnlyClassifier.assertReadOnly(sql), file: file, line: line)
    }

    private func assertRejected(
        _ sql: String,
        containing fragment: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try PostgresReadOnlyClassifier.assertReadOnly(sql)
            XCTFail("Expected rejection: \(sql)", file: file, line: line)
        } catch let error as PostgresReadOnlyViolation {
            if let fragment {
                XCTAssertTrue(
                    error.userMessage.contains(fragment),
                    "\(error.userMessage) should contain \(fragment)",
                    file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error type: \(error)", file: file, line: line)
        }
    }

    func testAcceptsReadOnlySQLWithQuotedKeywords() {
        assertAllowed(#"SELECT "update", 'delete; insert', $$drop table hidden$$ FROM "insert";"#)
        assertAllowed("WITH summary AS (SELECT 1) SELECT * FROM summary")
        assertAllowed("VALUES (1, 2), (3, 4)")
        assertAllowed("EXPLAIN SELECT 1")
        assertAllowed("TABLE pg_am")
        assertAllowed("SHOW TimeZone")
    }

    func testRejectsMutationsAndMultipleStatements() {
        assertRejected("WITH changed AS (DELETE FROM users) SELECT 1", containing: "DELETE")
        assertRejected("SELECT nextval('order_id_seq')", containing: "NEXTVAL")
        assertRejected("SELECT 1; SELECT 2", containing: "one SQL statement")
        assertRejected("DROP TABLE users")
        assertRejected("select 1; drop table users", containing: nil)
        assertRejected("UPDATE users SET admin = true")
        assertRejected("INSERT INTO logs VALUES (1)")
    }

    func testBackslashIsLiteralInPlainStringsButEscapeInEStrings() {
        // Regression: with standard_conforming_strings=on, `'\'` closes the
        // string and the DROP statement is real SQL — classification must
        // reject the payload. (TS source: `SELECT '\\'; DROP TABLE users; --'`)
        assertRejected(#"SELECT '\'; DROP TABLE users; --'"#)
        assertRejected(#"SELECT '\' DROP TABLE users"#, containing: "DROP")
        // In an E'...' escape string the same payload is inert string content.
        assertAllowed(#"SELECT E'\\\'; DROP TABLE users; --'"#)
        assertAllowed(#"SELECT e'it\'s fine', 1"#)
        // The regression case from the task brief must be rejected.
        assertRejected(#"SELECT ''\''; DROP TABLE users; --'"#)
    }

    func testEStringPrefixMustNotBeIdentifierTail() {
        // `mode` ends in `e` but is an identifier; the following string is
        // plain, so the payload after it is real SQL.
        assertRejected(#"SELECT mode'\'; DROP TABLE users; --'"#, containing: nil)
        assertRejected("SELECT 1e'\u{5c}' FROM x; DROP TABLE users; --'")
    }

    func testRejectsAdministrativeFunctions() {
        assertRejected(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity",
            containing: "PG_TERMINATE_BACKEND")
        assertRejected(
            "SELECT pg_cancel_backend(pid) FROM pg_stat_activity",
            containing: "PG_CANCEL_BACKEND")
        assertRejected("SELECT pg_reload_conf()", containing: "PG_RELOAD_CONF")
        assertRejected("SELECT pg_rotate_logfile()", containing: "PG_ROTATE_LOGFILE")
        assertRejected("SELECT set_config('statement_timeout', '0', false)", containing: "SET_CONFIG")
        assertRejected("SELECT pg_advisory_lock(1)", containing: "PG_ADVISORY_LOCK")
        assertRejected("SELECT pg_try_advisory_xact_lock(1)", containing: "PG_TRY_ADVISORY_XACT_LOCK")
    }

    func testCommentsAndDollarQuotingHidePayloads() {
        assertAllowed("SELECT 1 -- DROP TABLE users")
        assertAllowed("/* UPDATE users */ SELECT 1")
        assertAllowed("/* nested /* comment */ still comment */ SELECT 1")
        assertAllowed("SELECT $tag$DROP TABLE users$tag$")
        assertAllowed("SELECT $$x$$")
        assertRejected("/* unterminated SELECT 1", containing: "classify")
        assertRejected("SELECT $tag$unterminated", containing: "classify")
        assertRejected("SELECT 'unterminated", containing: "classify")
        assertRejected("-- only a comment")
    }

    func testFailClosedOnNonReadOnlyStarters() {
        assertRejected("VACUUM")
        assertRejected("SET statement_timeout = 0")
        assertRejected("BEGIN")
        assertRejected("")
        assertRejected("   ;  ")
    }
}
