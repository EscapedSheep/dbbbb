import Foundation
import dbbbbCore

/// Pure catalog query + row folding for PostgreSQL foreign-key introspection
/// (ROADMAP M1 ⑤). `pg_constraint` rows with `contype = 'f'` are expanded by
/// `conkey`/`confkey` ordinal so multi-column keys keep their column pairing;
/// schema and table names cross as binds, never as SQL text.
enum PostgresForeignKeyPlanner {
    /// (constraint, column, referenced schema/table/kind/column) rows for one
    /// table, ordered by constraint name then key ordinal. `$1`/`$2` bind the
    /// object's schema and name, constraining the lookup to that relation.
    static let listForeignKeysSQL = """
        SELECT con.conname::text,
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
          AND n.nspname = $1
          AND c.relname = $2
        ORDER BY con.conname, u.ord
        """

    /// Folds raw rows (already ordered by constraint name, then ordinal) into
    /// grouped foreign keys. Referenced object ids round-trip through
    /// `PostgresObjectIDCodec`, so they preview directly.
    static func foreignKeys(
        rows: [(constraint: String, column: String, referencedSchema: String,
                referencedTable: String, referencedKind: String, referencedColumn: String)]
    ) throws -> [ForeignKey] {
        var order: [String] = []
        var grouped: [String: (
            columns: [String], referencedObject: DatabaseObject, referencedColumns: [String]
        )] = [:]

        for row in rows {
            guard !row.constraint.isEmpty, !row.column.isEmpty,
                  !row.referencedSchema.isEmpty, !row.referencedTable.isEmpty,
                  !row.referencedColumn.isEmpty
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid foreign-key metadata.")
            }
            let referencedKind: PostgresObjectRef.Kind
            switch row.referencedKind {
            case "r", "p", "f": referencedKind = .table
            case "v", "m": referencedKind = .view
            default:
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid foreign-key metadata.")
            }
            let referencedRef = PostgresObjectRef(
                kind: referencedKind, schema: row.referencedSchema, name: row.referencedTable)
            let schemaRef = PostgresObjectRef(kind: .schema, schema: row.referencedSchema, name: nil)
            let referencedObject = DatabaseObject(
                id: PostgresObjectIDCodec.encode(referencedRef),
                parentID: PostgresObjectIDCodec.encode(schemaRef),
                name: row.referencedTable,
                kind: referencedKind == .view ? .view : .table)

            if grouped[row.constraint] == nil {
                order.append(row.constraint)
                grouped[row.constraint] = ([], referencedObject, [])
            }
            guard var entry = grouped[row.constraint],
                  entry.referencedObject == referencedObject,
                  !entry.columns.contains(row.column)
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid foreign-key metadata.")
            }
            entry.columns.append(row.column)
            entry.referencedColumns.append(row.referencedColumn)
            grouped[row.constraint] = entry
        }

        return order.map { name in
            let entry = grouped[name]!
            return ForeignKey(
                columns: entry.columns,
                referencedObject: entry.referencedObject,
                referencedColumns: entry.referencedColumns)
        }
    }
}
