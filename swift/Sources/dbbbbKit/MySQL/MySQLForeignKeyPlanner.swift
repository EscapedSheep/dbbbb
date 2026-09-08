import Foundation
import dbbbbCore

/// Pure catalog query + row folding for MySQL foreign-key introspection
/// (ROADMAP M1 ⑤). `information_schema.KEY_COLUMN_USAGE` rows are qualified
/// by the object's own schema (`?` binds, never interpolated) and carry the
/// referenced schema per row, so server-wide (database-less) connections and
/// cross-schema references stay correctly qualified.
enum MySQLForeignKeyPlanner {
    /// (constraint, column, referenced schema/table/column) rows for one
    /// table. `ORDINAL_POSITION` is the column's position within its
    /// constraint, preserving multi-column key pairing; the PRIMARY row and
    /// non-FK constraints carry a NULL referenced table and are excluded.
    static let listForeignKeysSQL = """
        SELECT CONSTRAINT_NAME,
               COLUMN_NAME,
               REFERENCED_TABLE_SCHEMA,
               REFERENCED_TABLE_NAME,
               REFERENCED_COLUMN_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = ?
          AND TABLE_NAME = ?
          AND CONSTRAINT_NAME <> 'PRIMARY'
          AND REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY CONSTRAINT_NAME, ORDINAL_POSITION
        """

    /// Folds raw rows (already ordered by constraint name, then ordinal)
    /// into grouped foreign keys. Referenced object ids come from the same
    /// `MySQLObjectRef` codec `listObjects` uses, so they preview directly.
    static func foreignKeys(
        rows: [(constraint: String, column: String, referencedSchema: String,
                referencedTable: String, referencedColumn: String)]
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
                throw MySQLAdapterError.failure(
                    "MySQL returned invalid foreign-key metadata.")
            }
            // Foreign keys reference base tables only.
            let referencedRef = MySQLObjectRef(
                kind: .table, database: row.referencedSchema, name: row.referencedTable)
            let schemaRef = MySQLObjectRef(kind: .database, database: row.referencedSchema, name: nil)
            let referencedObject = DatabaseObject(
                id: referencedRef.id,
                parentID: schemaRef.id,
                name: row.referencedTable,
                kind: .table)

            if grouped[row.constraint] == nil {
                order.append(row.constraint)
                grouped[row.constraint] = ([], referencedObject, [])
            }
            guard var entry = grouped[row.constraint],
                  entry.referencedObject == referencedObject,
                  !entry.columns.contains(row.column)
            else {
                throw MySQLAdapterError.failure(
                    "MySQL returned invalid foreign-key metadata.")
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
