import Foundation
import dbbbbCore

/// Pure query + row folding for SQLite foreign-key introspection (ROADMAP
/// M1 ⑤): the table-valued `pragma_foreign_key_list(?)` with the table name
/// bound, grouped by `id` in `seq` order. `REFERENCES t` without a column
/// list reports `to = NULL`; the adapter resolves those through
/// `implicitReferencedColumnsSQL` (the referenced table's primary key) and
/// passes the mapping in.
enum SQLiteForeignKeyPlanner {
    /// (id, seq, referenced table, column, referenced column) rows for one
    /// table; `to` is NULL for implicit-PK references.
    static let listForeignKeysSQL = """
        SELECT "id", "seq", "table", "from", "to"
        FROM pragma_foreign_key_list(?)
        ORDER BY "id", "seq"
        """

    /// Primary-key columns of a referenced table, in key order — the implicit
    /// target of a `REFERENCES t` clause without a column list.
    static let implicitReferencedColumnsSQL =
        "SELECT name FROM pragma_table_xinfo(?) WHERE pk > 0 ORDER BY pk"

    /// Folds resolved rows (already ordered by id, then seq) into grouped
    /// foreign keys. `implicitColumns` maps a referenced table to its
    /// primary-key columns for rows whose referenced column is NULL; a key
    /// whose implicit target cannot be resolved is dropped — a jump we cannot
    /// aim is never offered (fail closed).
    static func foreignKeys(
        rows: [(id: Int, column: String, referencedTable: String, referencedColumn: String?)],
        implicitColumns: [String: [String]]
    ) throws -> [ForeignKey] {
        var order: [Int] = []
        var grouped: [Int: (
            columns: [String], referencedTable: String, referencedColumns: [String]
        )] = [:]
        // Total rows per key: an implicitly resolved key is emitted only when
        // every column resolved, never as a half-aimed jump.
        var expectedCounts: [Int: Int] = [:]

        for row in rows {
            guard !row.column.isEmpty, !row.referencedTable.isEmpty else {
                throw SQLiteAdapterError("SQLite returned invalid foreign-key metadata.")
            }
            expectedCounts[row.id, default: 0] += 1
            if grouped[row.id] == nil {
                order.append(row.id)
                grouped[row.id] = ([], row.referencedTable, [])
            }
            guard var entry = grouped[row.id],
                  entry.referencedTable == row.referencedTable,
                  !entry.columns.contains(row.column)
            else {
                throw SQLiteAdapterError("SQLite returned invalid foreign-key metadata.")
            }
            let referencedColumn: String
            if let explicit = row.referencedColumn {
                referencedColumn = explicit
            } else {
                let implicit = implicitColumns[row.referencedTable] ?? []
                guard entry.columns.count < implicit.count else { continue }
                referencedColumn = implicit[entry.columns.count]
            }
            entry.columns.append(row.column)
            entry.referencedColumns.append(referencedColumn)
            grouped[row.id] = entry
        }

        return order.compactMap { id in
            guard let entry = grouped[id],
                  entry.columns.count == expectedCounts[id],
                  entry.columns.count == entry.referencedColumns.count,
                  !entry.columns.isEmpty
            else { return nil }
            let referencedObject = DatabaseObject(
                id: SQLiteAdapter.objectID(kind: .table, name: entry.referencedTable),
                parentID: SQLiteAdapter.objectID(kind: .schema, name: nil),
                name: entry.referencedTable,
                kind: .table)
            return ForeignKey(
                columns: entry.columns,
                referencedObject: referencedObject,
                referencedColumns: entry.referencedColumns)
        }
    }
}
