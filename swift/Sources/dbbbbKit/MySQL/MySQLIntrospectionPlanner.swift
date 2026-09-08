import Foundation
import dbbbbCore

/// Pure statement builder for the MySQL create-statement introspection.
enum MySQLIntrospectionPlanner {
    /// Identifiers are backtick-quoted exactly like the preview path; the
    /// dedicated view form keeps the reply column names stable across
    /// server versions (`SHOW CREATE TABLE` also answers for views, but the
    /// view form is the documented shape).
    static func showCreateStatementSQL(database: String, name: String, isView: Bool) -> String {
        let qualified = MySQLAdapter.quoteIdentifier(database)
            + "." + MySQLAdapter.quoteIdentifier(name)
        return isView ? "SHOW CREATE VIEW \(qualified)" : "SHOW CREATE TABLE \(qualified)"
    }
}
