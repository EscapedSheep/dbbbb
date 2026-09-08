import Foundation
import dbbbbCore

/// Pure catalog queries + row folding for PostgreSQL structured-schema
/// introspection ("View Schema"). Columns come from `pg_attribute` joined
/// against the table's primary-key constraint (ordinal position preserved);
/// indexes from `pg_index` with `indkey` expanded by ordinality. Schema and
/// table names cross as binds, never as SQL text — same discipline as
/// `PostgresForeignKeyPlanner`.
enum PostgresSchemaPlanner {
    /// (name, display type, nullable, primary-key ordinal) rows for one
    /// table, ordered by `attnum`. `$1`/`$2` bind the object's schema and
    /// name. Dropped and system columns are excluded; the primary-key ordinal
    /// is 0 for non-key columns.
    static let listColumnsSQL = """
        SELECT a.attname::text,
               pg_catalog.format_type(a.atttypid, a.atttypmod),
               (NOT a.attnotnull)::text,
               COALESCE(pk.ord, 0)
        FROM pg_catalog.pg_attribute AS a
        JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        LEFT JOIN LATERAL (
            SELECT u.ord
            FROM pg_catalog.pg_constraint AS con
            CROSS JOIN LATERAL unnest(con.conkey)
              WITH ORDINALITY AS u(attnum, ord)
            WHERE con.conrelid = c.oid
              AND con.contype = 'p'
              AND u.attnum = a.attnum
        ) AS pk ON true
        WHERE n.nspname = $1
          AND c.relname = $2
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """

    /// (index name, is unique, column) rows for one table, ordered by index
    /// name then key ordinal. Expression columns (`indkey` 0) join no
    /// attribute and drop out, so an expression-only index folds away.
    static let listIndexesSQL = """
        SELECT i.relname::text,
               ix.indisunique::text,
               a.attname::text
        FROM pg_catalog.pg_index AS ix
        JOIN pg_catalog.pg_class AS t ON t.oid = ix.indrelid
        JOIN pg_catalog.pg_namespace AS n ON n.oid = t.relnamespace
        JOIN pg_catalog.pg_class AS i ON i.oid = ix.indexrelid
        CROSS JOIN LATERAL unnest(ix.indkey)
          WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_catalog.pg_attribute AS a
          ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE n.nspname = $1
          AND t.relname = $2
        ORDER BY i.relname, k.ord
        """

    /// (source schema/table, constraint, column, referenced
    /// schema/table/kind/column) rows for every user schema — the
    /// `PostgresForeignKeyPlanner.listForeignKeysSQL` shape widened with the
    /// source relation and without its table filter, ordered so each table's
    /// constraints arrive grouped in ordinal order.
    static let listAllForeignKeysSQL = """
        SELECT n.nspname::text,
               c.relname::text,
               con.conname::text,
               a.attname::text,
               rn.nspname::text,
               rc.relname::text,
               rc.relkind::text,
               fa.attname::text
        FROM pg_catalog.pg_constraint AS con
        JOIN pg_catalog.pg_class AS c ON c.oid = con.conrelid
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        CROSS JOIN LATERAL unnest(con.conkey, con.confkey)
          WITH ORDINALITY AS u(conattnum, confattnum, ord)
        JOIN pg_catalog.pg_attribute AS a
          ON a.attrelid = con.conrelid AND a.attnum = u.conattnum
        JOIN pg_catalog.pg_class AS rc ON rc.oid = con.confrelid
        JOIN pg_catalog.pg_namespace AS rn ON rn.oid = rc.relnamespace
        JOIN pg_catalog.pg_attribute AS fa
          ON fa.attrelid = rc.oid AND fa.attnum = u.confattnum
        WHERE con.contype = 'f'
          AND n.nspname <> 'information_schema'
          AND n.nspname !~ '^pg_'
        ORDER BY n.nspname, c.relname, con.conname, u.ord
        """

    /// Folds (already attnum-ordered) rows into column schemas. Malformed
    /// rows fail closed: empty names and negative ordinals refuse the result.
    static func columns(
        rows: [(name: String, dataType: String, nullable: Bool, primaryKeyOrdinal: Int)]
    ) throws -> [ColumnSchema] {
        var seen: Set<String> = []
        var columns: [ColumnSchema] = []
        for row in rows {
            guard !row.name.isEmpty, row.primaryKeyOrdinal >= 0, seen.insert(row.name).inserted
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid schema metadata.")
            }
            columns.append(ColumnSchema(
                name: row.name,
                dataType: row.dataType,
                nullable: row.nullable,
                primaryKeyOrdinal: row.primaryKeyOrdinal))
        }
        return columns
    }

    /// Folds (index-name, then ordinal ordered) rows into grouped indexes.
    /// Indexes whose columns all dropped out (expression-only) yield nothing.
    static func indexes(
        rows: [(name: String, isUnique: Bool, column: String)]
    ) throws -> [IndexSchema] {
        var order: [String] = []
        var grouped: [String: (isUnique: Bool, columns: [String])] = [:]
        for row in rows {
            guard !row.name.isEmpty, !row.column.isEmpty else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid schema metadata.")
            }
            if grouped[row.name] == nil {
                order.append(row.name)
                grouped[row.name] = (row.isUnique, [])
            }
            guard var entry = grouped[row.name],
                  entry.isUnique == row.isUnique,
                  !entry.columns.contains(row.column)
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid schema metadata.")
            }
            entry.columns.append(row.column)
            grouped[row.name] = entry
        }
        return order.compactMap { name in
            guard let entry = grouped[name], !entry.columns.isEmpty else { return nil }
            return IndexSchema(name: name, columns: entry.columns, isUnique: entry.isUnique)
        }
    }

    /// Folds rows (grouped by source table, constraint, ordinal) into
    /// database-wide edges: each table's rows replay through the single-table
    /// `PostgresForeignKeyPlanner` folding, so multi-column pairing and
    /// malformed-row handling stay identical.
    static func allForeignKeys(
        rows: [(schema: String, table: String, constraint: String, column: String,
                referencedSchema: String, referencedTable: String,
                referencedKind: String, referencedColumn: String)]
    ) throws -> [TableRelation] {
        var order: [(schema: String, table: String)] = []
        var grouped: [String: [(constraint: String, column: String, referencedSchema: String,
                                referencedTable: String, referencedKind: String,
                                referencedColumn: String)]] = [:]
        for row in rows {
            guard !row.schema.isEmpty, !row.table.isEmpty else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid foreign-key metadata.")
            }
            let key = "\(row.schema)\u{1F}\(row.table)"
            if grouped[key] == nil {
                order.append((row.schema, row.table))
                grouped[key] = []
            }
            grouped[key]?.append((row.constraint, row.column, row.referencedSchema,
                                  row.referencedTable, row.referencedKind, row.referencedColumn))
        }

        var relations: [TableRelation] = []
        for source in order {
            let key = "\(source.schema)\u{1F}\(source.table)"
            let keys = try PostgresForeignKeyPlanner.foreignKeys(rows: grouped[key] ?? [])
            let tableRef = PostgresObjectRef(kind: .table, schema: source.schema, name: source.table)
            let schemaRef = PostgresObjectRef(kind: .schema, schema: source.schema, name: nil)
            let object = DatabaseObject(
                id: PostgresObjectIDCodec.encode(tableRef),
                parentID: PostgresObjectIDCodec.encode(schemaRef),
                name: source.table,
                kind: .table)
            relations.append(contentsOf: keys.map { TableRelation(object: object, foreignKey: $0) })
        }
        return relations
    }
}
