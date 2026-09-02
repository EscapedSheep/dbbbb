import XCTest
@testable import dbbbbKit

final class SQLClassifierTests: XCTestCase {
    private func assertAllowed(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try assertSQLiteReadOnlySQL(sql), sql, file: file, line: line)
    }

    private func assertRejected(_ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try assertSQLiteReadOnlySQL(sql), sql, file: file, line: line)
    }

    // MARK: - Allowed read-only statements

    func testAllowsPlainSelect() {
        assertAllowed("SELECT 1")
        assertAllowed("  select * from t  ")
        assertAllowed("SELECT\n*\nFROM t\nWHERE x = 1")
    }

    func testAllowsWithAndExplain() {
        assertAllowed("WITH x AS (SELECT 1) SELECT * FROM x")
        assertAllowed("EXPLAIN SELECT 1")
        assertAllowed("EXPLAIN QUERY PLAN SELECT * FROM t")
    }

    func testAllowsTokensInsideLiteralsAndIdentifiers() {
        assertAllowed("SELECT 'DELETE FROM t' AS note")
        assertAllowed("SELECT \"DROP\" FROM t")
        assertAllowed("SELECT `INSERT` FROM t")
        assertAllowed("SELECT [UPDATE] FROM t")
        assertAllowed("SELECT 'it''s fine' FROM t")
    }

    func testAllowsTrailingCommentAndSemicolon() {
        assertAllowed("SELECT 1; -- trailing comment")
        assertAllowed("SELECT 1; /* trailing block */")
        assertAllowed("-- leading comment\nSELECT 1")
        assertAllowed("/* leading */ SELECT 1 -- tail")
    }

    // MARK: - Rejected statements

    func testRejectsWrites() {
        assertRejected("INSERT INTO t VALUES (1)")
        assertRejected("UPDATE t SET x = 1")
        assertRejected("DELETE FROM t")
        assertRejected("DROP TABLE t")
        assertRejected("CREATE TABLE t (x INTEGER)")
        assertRejected("REPLACE INTO t VALUES (1)")
        assertRejected("ALTER TABLE t ADD COLUMN y INTEGER")
    }

    func testRejectsWriteHiddenInWith() {
        assertRejected("WITH x AS (SELECT 1) DELETE FROM t")
        assertRejected("WITH x AS (SELECT 1) UPDATE t SET y = 1")
    }

    func testAllowsLoadExtensionSelectLikeReference() {
        // Parity with the Electron reference: the token list does not cover
        // functions; SQLite itself keeps load_extension disabled by default.
        assertAllowed("SELECT load_extension('x')")
    }

    func testRejectsPragmaAttachVacuumTransactions() {
        assertRejected("PRAGMA table_info(t)")
        assertRejected("SELECT * FROM pragma_table_info('t')")
        assertRejected("ATTACH DATABASE 'other.db' AS other")
        assertRejected("DETACH DATABASE other")
        assertRejected("VACUUM")
        assertRejected("BEGIN TRANSACTION")
        assertRejected("COMMIT")
        assertRejected("ROLLBACK")
        assertRejected("SAVEPOINT s")
        assertRejected("RELEASE s")
        assertRejected("ANALYZE")
        assertRejected("REINDEX")
    }

    func testRejectsMultipleStatements() {
        assertRejected("SELECT 1; SELECT 2")
        assertRejected("SELECT * FROM t; DROP TABLE t; --")
        assertRejected("SELECT 1; INSERT INTO t VALUES (1)")
    }

    func testRejectsAmbiguousInputFailClosed() {
        assertRejected("SELECT 'unterminated")
        assertRejected("SELECT `unterminated")
        assertRejected("SELECT [unterminated")
        assertRejected("/* unterminated SELECT 1")
        // SQLite block comments do not nest; the classifier refuses to guess.
        assertRejected("/* nested /* opener */ SELECT 1")
    }

    func testRejectsEmptyAndUnknownStarters() {
        assertRejected("")
        assertRejected("   ")
        assertRejected("-- only a comment")
        assertRejected("VALUES (1)")
    }

    // MARK: - Single-statement rule for writable sessions

    func testInspectAllowsWriteStatementsWhenNotReadOnly() throws {
        XCTAssertEqual(try inspectSQLiteSQL("DELETE FROM t WHERE id = 1"), ["DELETE", "FROM", "T", "WHERE", "ID"])
        XCTAssertEqual(try inspectSQLiteSQL("INSERT INTO t VALUES ('a; b')"), ["INSERT", "INTO", "T", "VALUES"])
    }

    func testInspectRejectsMultipleStatementsEvenWhenNotReadOnly() {
        XCTAssertThrowsError(try inspectSQLiteSQL("SELECT 1; SELECT 2")) { error in
            XCTAssertEqual((error as? SQLiteAdapterError)?.userMessage,
                           "SQLite connections only allow one SQL statement at a time.")
        }
    }
}
