import Foundation
import dbbbbCore

/// One column of a reconstructed CREATE TABLE.
struct PostgresIntrospectionColumn: Sendable, Equatable {
    let name: String
    let type: String
    let notNull: Bool
    let defaultExpression: String?
}

/// Pure assembly + catalog queries for the PostgreSQL create-statement
/// introspection. PostgreSQL has no SHOW CREATE, so the DDL is
/// *reconstructed* from pg_catalog: columns with type / NOT NULL / default,
/// the primary key constraint, unique indexes via `pg_get_indexdef`, and
/// views via `pg_get_viewdef`. This is a readable approximation, NOT
/// pg_dump-grade: partitioning clauses, tablespaces, inheritance, check and
/// foreign-key constraints, triggers, RLS policies, ownership, and
/// privileges are not reproduced.
enum PostgresIntrospectionPlanner {
    /// Relation oid lookup by (schema, name); `$1`/`$2` bind the names and
    /// the relkind set is fixed at plan time (no user input reaches the SQL).
    static func relationOIDSQL(isView: Bool) -> String {
        let kinds = isView ? "'v', 'm'" : "'r', 'p', 'f'"
        return """
            SELECT c.oid
            FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
              AND c.relname = $2
              AND c.relkind IN (\(kinds))
            """
    }

    /// The relation oid is a server-generated number, interpolated the same
    /// way `pg_cancel_backend` interpolates the backend PID.
    static func columnListingSQL(relationOID: UInt32) -> String {
        """
        SELECT a.attname::text,
               pg_catalog.format_type(a.atttypid, a.atttypmod),
               a.attnotnull::text,
               pg_catalog.pg_get_expr(d.adbin, d.adrelid)
        FROM pg_catalog.pg_attribute AS a
        LEFT JOIN pg_catalog.pg_attrdef AS d
          ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = \(relationOID)
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }

    /// (constraint name, column name) rows in key order.
    static func primaryKeySQL(relationOID: UInt32) -> String {
        """
        SELECT con.conname::text, a.attname::text
        FROM pg_catalog.pg_constraint AS con
        CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
        JOIN pg_catalog.pg_attribute AS a
          ON a.attrelid = con.conrelid AND a.attnum = u.attnum
        WHERE con.conrelid = \(relationOID)
          AND con.contype = 'p'
        ORDER BY u.ord
        """
    }

    /// Server-rendered CREATE UNIQUE INDEX statements (pk excluded; it is
    /// inlined as a table constraint instead).
    static func uniqueIndexSQL(relationOID: UInt32) -> String {
        """
        SELECT pg_catalog.pg_get_indexdef(i.indexrelid)
        FROM pg_catalog.pg_index AS i
        WHERE i.indrelid = \(relationOID)
          AND i.indisunique
          AND NOT i.indisprimary
        ORDER BY 1
        """
    }

    static func viewDefinitionSQL(relationOID: UInt32) -> String {
        "SELECT pg_catalog.pg_get_viewdef(\(relationOID), true)"
    }

    /// Assembles the reconstructed CREATE TABLE: column lines with defaults
    /// and NOT NULL, the inline primary-key constraint, then the unique
    /// index statements (already server-rendered, semicolons added).
    static func createTableStatement(
        schema: String,
        name: String,
        columns: [PostgresIntrospectionColumn],
        primaryKey: (constraintName: String, columns: [String])?,
        uniqueIndexDefinitions: [String]
    ) throws -> String {
        guard !columns.isEmpty else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL returned no column metadata for this object.")
        }
        let qualifiedTable = try "\(PostgresChangePlanner.quoteIdentifier(schema))"
            + ".\(PostgresChangePlanner.quoteIdentifier(name))"
        var lines: [String] = []
        for column in columns {
            var line = "    \(try PostgresChangePlanner.quoteIdentifier(column.name)) \(column.type)"
            if let defaultExpression = column.defaultExpression, !defaultExpression.isEmpty {
                line += " DEFAULT \(defaultExpression)"
            }
            if column.notNull {
                line += " NOT NULL"
            }
            lines.append(line)
        }
        if let primaryKey, !primaryKey.columns.isEmpty {
            let quotedColumns = try primaryKey.columns
                .map { try PostgresChangePlanner.quoteIdentifier($0) }
                .joined(separator: ", ")
            let constraint = try PostgresChangePlanner.quoteIdentifier(primaryKey.constraintName)
            lines.append("    CONSTRAINT \(constraint) PRIMARY KEY (\(quotedColumns))")
        }
        var statement = "CREATE TABLE \(qualifiedTable) (\n"
            + lines.joined(separator: ",\n")
            + "\n);"
        for definition in uniqueIndexDefinitions {
            let trimmed = definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            statement += "\n\n" + (trimmed.hasSuffix(";") ? trimmed : trimmed + ";")
        }
        return statement
    }

    /// The server-rendered view body behind a quoted CREATE VIEW header.
    static func createViewStatement(schema: String, name: String, definition: String) throws -> String {
        var body = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast() }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL returned no view definition for this object.")
        }
        let qualifiedView = try "\(PostgresChangePlanner.quoteIdentifier(schema))"
            + ".\(PostgresChangePlanner.quoteIdentifier(name))"
        return "CREATE VIEW \(qualifiedView) AS\n\(body);"
    }
}
