import XCTest
@testable import dbbbbKit

final class MySQLReadOnlyClassifierTests: XCTestCase {
    // MARK: - Allowed statements

    func testAllowsPlainSelect() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 1"))
    }

    func testAllowsLowercaseSelect() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("select * from users"))
    }

    func testAllowsWithShowDescribeExplain() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("WITH cte AS (SELECT 1 AS a) SELECT * FROM cte"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SHOW TABLES"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("DESCRIBE users"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("EXPLAIN SELECT * FROM users"))
    }

    func testAllowsLeadingComments() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("# hash comment\nSELECT 1"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("-- dash comment\nSELECT 1"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("/* block comment */ SELECT 1"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("/* multi\nline\n*/ SELECT 1"))
    }

    func testAllowsTrailingSemicolonAndWhitespace() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 1;"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("  SELECT 1 ;  \n"))
    }

    func testAllowsSemicolonInsideString() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 'a;b'"))
    }

    func testAllowsForbiddenWordsInsideLiterals() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 'DROP TABLE users'"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT \"DELETE FROM users\""))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT * FROM `KILL`"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT `weird``name` FROM t"))
    }

    func testAllowsDashDashExpression() {
        // `1--1` is a valid MySQL expression: `--` is a comment only when
        // whitespace or EOF follows.
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 1--1"))
    }

    func testAllowsDashDashAtEndOfInput() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 1 --"))
    }

    func testAllowsDoubledQuoteEscapes() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 'it''s fine'"))
    }

    func testBackslashEscapeKeepsFollowingQuoteInsideString() {
        // With NO_BACKSLASH_ESCAPES off (the MySQL default), \' is an escaped
        // quote, so the whole tail is one string literal and no DROP token exists.
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly(#"SELECT 'a\'; DROP TABLE t'"#))
    }

    func testBackslashIsNotAnEscapeInBacktickIdentifiers() {
        // `a\` ends the identifier at the second backtick; what follows is
        // visible SQL, so the SET token must be caught.
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly(#"SELECT `a\` SET `b`"#)) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("SET"))
        }
    }

    // MARK: - Rejected statements

    func testRejectsWriteStatements() {
        for sql in [
            "INSERT INTO t VALUES (1)",
            "UPDATE t SET a = 1",
            "DELETE FROM t",
            "DROP TABLE t",
            "CREATE TABLE t (a INT)",
            "ALTER TABLE t ADD COLUMN b INT",
            "TRUNCATE TABLE t",
            "REPLACE INTO t VALUES (1)",
            "GRANT SELECT ON *.* TO 'u'",
            "SET @a = 1",
            "USE other_db",
            "KILL 123",
            "CALL do_thing()",
            "LOCK TABLES t READ",
            "START TRANSACTION",
        ] {
            XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly(sql), sql)
        }
    }

    func testRejectsForbiddenTokensInsideSelect() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT * INTO OUTFILE '/tmp/x' FROM t")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("INTO"))
        }
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT GET_LOCK('a', 1)")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("GET_LOCK"))
        }
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT * FROM t LOCK IN SHARE MODE")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("LOCK"))
        }
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT RELEASE_LOCK('a')")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("RELEASE_LOCK"))
        }
    }

    func testRejectsWriteAfterWithStarter() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("WITH cte AS (SELECT 1) UPDATE t SET a = 1")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("UPDATE"))
        }
    }

    func testRejectsVersionedCommentsFailClosed() {
        // `/*! ... */` executes on matching server versions; even a benign-looking
        // statement wrapped in one cannot be proven inert.
        for sql in [
            "/*!80000 SET SESSION sql_mode=''*/ SELECT 1",
            "SELECT /*! SQL_NO_CACHE */ * FROM t",
        ] {
            XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly(sql), sql) { error in
                guard case MySQLAdapterError.unclassifiableSQL = error else {
                    return XCTFail("expected unclassifiableSQL, got \(error)")
                }
            }
        }
    }

    func testSpacedBangBlockCommentIsNotVersioned() {
        // `/* !` with a space is a plain comment, not a versioned one.
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("/* ! not versioned */ SELECT 1"))
    }

    func testPlainBlockCommentFollowedBySelectIsFine() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("/* harmless */ SELECT 1"))
    }

    func testRejectsMultipleStatements() {
        for sql in [
            "SELECT 1; SELECT 2",
            "SELECT 1; DROP TABLE t",
            ";",
            "SELECT 1;;SELECT 2",
        ] {
            XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly(sql), sql) { error in
                XCTAssertEqual(error as? MySQLAdapterError, .multipleStatements)
            }
        }
    }

    func testRejectsEmptyStatement() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("   ")) { error in
            // No visible tokens at all: zero statements after stripping.
            XCTAssertEqual(error as? MySQLAdapterError, .multipleStatements)
        }
    }

    func testRejectsUnterminatedStringFailClosed() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 'oops")) { error in
            guard case MySQLAdapterError.unclassifiableSQL = error else {
                return XCTFail("expected unclassifiableSQL, got \(error)")
            }
        }
    }

    func testRejectsUnterminatedBacktickFailClosed() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT `oops")) { error in
            guard case MySQLAdapterError.unclassifiableSQL = error else {
                return XCTFail("expected unclassifiableSQL, got \(error)")
            }
        }
    }

    func testRejectsUnterminatedBlockCommentFailClosed() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 1 /* oops")) { error in
            guard case MySQLAdapterError.unclassifiableSQL = error else {
                return XCTFail("expected unclassifiableSQL, got \(error)")
            }
        }
    }

    func testNonReadOnlyStarterRejected() {
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("DELETE FROM t WHERE id = 1")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .statementNotReadOnly)
        }
    }

    func testTokensAreExtractedFromVisibleSql() throws {
        let tokens = try MySQLReadOnlyClassifier.visibleTokens(
            "SELECT `a`, 'b' FROM t WHERE x = 1 -- INTO\n"
        )
        XCTAssertEqual(tokens, ["SELECT", "FROM", "T", "WHERE", "X"])
    }

    // MARK: - EXPLAIN viewer regression (ROADMAP M2 ⑧)

    /// The Explain feature relies on the classifier allowing EXPLAIN; the
    /// ANALYZE token (EXPLAIN ANALYZE executes the statement on MySQL 8.0.18+)
    /// must stay rejected.
    func testExplainAllowedButAnalyzeStaysRejected() {
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("EXPLAIN SELECT 1"))
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("EXPLAIN FORMAT=JSON SELECT 1"))
        XCTAssertThrowsError(try MySQLReadOnlyClassifier.assertReadOnly("EXPLAIN ANALYZE SELECT 1")) { error in
            XCTAssertEqual(error as? MySQLAdapterError, .forbiddenToken("ANALYZE"))
        }
        XCTAssertNoThrow(try MySQLReadOnlyClassifier.assertReadOnly("SELECT 'analyze me'"))
    }
}
