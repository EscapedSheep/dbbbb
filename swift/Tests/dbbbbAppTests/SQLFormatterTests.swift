import Foundation
import Testing
import dbbbbCore
@testable import dbbbbApp

/// SQL formatter tests (ROADMAP M3 查询格式化): tokenizer fidelity, layout
/// rules, and above all the safety contract — formatting never changes the
/// token stream (round-trip invariant), and anything unrecognized degrades
/// to the verbatim input.
struct SQLFormatterTests {
    // MARK: Tokenizer

    @Test func stringsWithEscapesStayVerbatim() {
        #expect(SQLFormatter.tokenize("select 'it''s'").map(\.text) == ["select", "'it''s'"])
        #expect(SQLFormatter.tokenize("select 'back\\'slash'").map(\.text) == ["select", "'back\\'slash'"])
        // A keyword inside a string is one string token, never a word.
        #expect(SQLFormatter.tokenize("'select from'").map(\.kind) == [.string])
    }

    @Test func quotedIdentifiersStayVerbatim() {
        #expect(SQLFormatter.tokenize(#"select "My ""Col""" from `weird``name`"#)
            .map(\.text) == ["select", "\"My \"\"Col\"\"\"", "from", "`weird``name`"])
        #expect(SQLFormatter.tokenize(#""a b""#).map(\.kind) == [.quotedIdentifier])
    }

    @Test func dollarQuotedStringsStayVerbatim() {
        let body = "$body$ select 'x' ; $body$"
        #expect(SQLFormatter.tokenize("select \(body)").map(\.text) == ["select", body])
        #expect(SQLFormatter.tokenize("$$plain$$").map(\.text) == ["$$plain$$"])
        // Unterminated: runs to the end as one token, nothing invented.
        #expect(SQLFormatter.tokenize("$x$ open").map(\.text) == ["$x$ open"])
        // A $1 parameter placeholder is a symbol + number, not a quote.
        #expect(SQLFormatter.tokenize("where a = $1").map(\.kind)
            == [.word, .word, .symbol, .symbol, .number])
    }

    @Test func commentsAreSingleTokens() {
        #expect(SQLFormatter.tokenize("select 1 -- tail").map(\.text)
            == ["select", "1", "-- tail"])
        #expect(SQLFormatter.tokenize("/* a ; b */ select").map(\.text)
            == ["/* a ; b */", "select"])
        // Unterminated block comment runs to the end.
        #expect(SQLFormatter.tokenize("/* open").map(\.text) == ["/* open"])
    }

    @Test func numbersAndOperators() {
        #expect(SQLFormatter.tokenize("1.5 0xFF 1e-10").map(\.text) == ["1.5", "0xFF", "1e-10"])
        #expect(SQLFormatter.tokenize("a::int").map(\.text) == ["a", "::", "int"])
        #expect(SQLFormatter.tokenize("a->>b").map(\.text) == ["a", "->>", "b"])
        #expect(SQLFormatter.tokenize("a>=b").map(\.text) == ["a", ">=", "b"])
    }

    // MARK: Layout

    @Test func mainClausesBreakAndConditionsIndent() {
        let formatted = SQLFormatter.format(
            "select id, name from users where age > 1 and name = 'x' order by name")
        #expect(formatted == """
            select id,
              name
            from users
            where age > 1
              and name = 'x'
            order by name
            """)
    }

    @Test func joinChainsBreakPerJoin() {
        let formatted = SQLFormatter.format(
            "select * from a left join b on a.id = b.id inner join c on b.x = c.x")
        #expect(formatted == """
            select *
            from a
            left join b on a.id = b.id
            inner join c on b.x = c.x
            """)
    }

    @Test func subqueryGetsItsOwnIndentedFrame() {
        let formatted = SQLFormatter.format(
            "select * from (select id, x from t where x > 0) y where y.id > 1")
        #expect(formatted == """
            select *
            from (
              select id,
                x
              from t
              where x > 0
            ) y
            where y.id > 1
            """)
    }

    @Test func functionCallsAndTuplesStayInline() {
        // A word before "(" binds tight (function-call convention), so the
        // INSERT column list reads as `log(a, b)` — valid, tokens intact.
        let formatted = SQLFormatter.format(
            "insert into log (a, b) values (1, 'x'), (2, 'y')")
        #expect(formatted == """
            insert into log(a, b)
            values (1, 'x'), (2, 'y')
            """)
        #expect(SQLFormatter.format("select count(*) from t") == "select count(*)\nfrom t")
        // update … set … where …
        #expect(SQLFormatter.format("update t set a = 1 where id = 2") == """
            update t
            set a = 1
            where id = 2
            """)
    }

    @Test func lineCommentForcesNewline() {
        // Whatever follows a line comment must start a new line, or it would
        // join the comment.
        let formatted = SQLFormatter.format("select id -- the id\nfrom t")
        #expect(formatted == "select id -- the id\nfrom t")
    }

    @Test func multiStatementSeparates() {
        #expect(SQLFormatter.format("select 1; select 2") == "select 1;\nselect 2")
    }

    @Test func keywordInsideStringIsNotALayoutTrigger() {
        let formatted = SQLFormatter.format("select 'from where' from t")
        #expect(formatted == "select 'from where'\nfrom t")
    }

    // MARK: Safety contract

    /// The round-trip invariant over a battery of shapes: formatting only
    /// re-lays whitespace; the token stream is byte-identical.
    @Test func roundTripInvariant() {
        let samples = [
            "select id, name from users where age > 1 and name = 'x' order by name",
            "SELECT * FROM a LEFT OUTER JOIN b ON a.id = b.id",
            "select * from (select id from t) x where x.id in (select id from u)",
            "insert into t (a, b) values (1, 'x'), (2, 'y')",
            "update t set a = 'it''s', b = NULL where id = 2 and x <> 3 or y >= 4",
            "delete from t where id = $1",
            "select $$body ; $$, $tag$x $tag$ from f('a,b')",
            "select 1 -- trailing\nfrom t /* mid */ where x = 0xFF",
            "with c as (select 1) select * from c union select 2 limit 10 offset 5",
            "select \"quoted col\", `tick col` from \"my table\"",
            "select 1.5e10, .5, 0x1A from dual",
            "CREATE TABLE t (a int, b text)",
        ]
        for sample in samples {
            let once = SQLFormatter.format(sample)
            #expect(SQLFormatter.tokenize(once) == SQLFormatter.tokenize(sample),
                    "token stream changed for: \(sample)")
            // Idempotent: formatting an already formatted query is a no-op.
            #expect(SQLFormatter.format(once) == once, "not idempotent for: \(sample)")
        }
    }

    @Test func emptyWhitespaceAndCommentOnlyInputsPassThrough() {
        #expect(SQLFormatter.format("") == "")
        #expect(SQLFormatter.format("  \n ") == "  \n ")
        #expect(SQLFormatter.format("-- only a comment") == "-- only a comment")
    }

    @Test func caseIsPreserved() {
        #expect(SQLFormatter.format("SeLeCt 1 FrOm t") == "SeLeCt 1\nFrOm t")
    }
}
