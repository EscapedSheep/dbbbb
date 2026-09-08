import Foundation
import dbbbbCore

/// Pure queries + row folding for SQLite structured-schema introspection
/// ("View Schema"): the table-valued `pragma_table_info(?)`,
/// `pragma_index_list(?)`, and `pragma_index_info(?)` with names bound, never
/// interpolated. Foreign keys reuse `SQLiteForeignKeyPlanner` wholesale.
enum SQLiteSchemaPlanner {
    /// (name, declared type, not-null flag, primary-key ordinal) rows for one
    /// table, in `cid` order. The declared type can be empty (SQLite type
    /// affinity); `pk` is the 1-based key position, 0 for non-key columns.
    static let listColumnsSQL = """
        SELECT name, type, "notnull", pk
        FROM pragma_table_info(?)
        ORDER BY cid
        """

    /// (name, unique flag) rows for one table's indexes, in list order. All
    /// origins are included (pk/u/c) — the viewer shows every index.
    static let listIndexesSQL = """
        SELECT name, "unique"
        FROM pragma_index_list(?)
        ORDER BY seq
        """

    /// Column names of one index, in key order. Expression legs report a NULL
    /// name and are filtered out here, so an expression-only index folds away.
    static let listIndexColumnsSQL = """
        SELECT name
        FROM pragma_index_info(?)
        WHERE name IS NOT NULL
        ORDER BY seqno
        """

    /// User tables of the database file, mirroring the navigator's filter —
    /// the scope of the database-wide relationship overview.
    static let listTablesSQL = """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """

    /// Folds (already cid-ordered) rows into column schemas. Malformed rows
    /// fail closed: empty names and negative ordinals refuse the result.
    static func columns(
        rows: [(name: String, dataType: String, notNull: Bool, primaryKeyOrdinal: Int)]
    ) throws -> [ColumnSchema] {
        var seen: Set<String> = []
        var columns: [ColumnSchema] = []
        for row in rows {
            guard !row.name.isEmpty, row.primaryKeyOrdinal >= 0,
                  seen.insert(row.name).inserted
            else {
                throw SQLiteAdapterError("SQLite returned invalid schema metadata.")
            }
            columns.append(ColumnSchema(
                name: row.name,
                dataType: row.dataType,
                // `INTEGER PRIMARY KEY` reports notnull=0 (a SQLite quirk),
                // but a key column can never hold NULL.
                nullable: !row.notNull && row.primaryKeyOrdinal == 0,
                primaryKeyOrdinal: row.primaryKeyOrdinal))
        }
        return columns
    }

    /// Pairs index rows with their (separately fetched) column lists.
    /// Expression and partial indexes report no columns through
    /// `pragma_index_info` and fold away — an index we cannot describe is
    /// never half-shown. Indexes whose column fetch failed are dropped too.
    static func indexes(
        rows: [(name: String, isUnique: Bool)],
        columns: [String: [String]]
    ) throws -> [IndexSchema] {
        var seen: Set<String> = []
        var indexes: [IndexSchema] = []
        for row in rows {
            guard !row.name.isEmpty, seen.insert(row.name).inserted else {
                throw SQLiteAdapterError("SQLite returned invalid schema metadata.")
            }
            guard let indexColumns = columns[row.name], !indexColumns.isEmpty else { continue }
            indexes.append(IndexSchema(name: row.name, columns: indexColumns, isUnique: row.isUnique))
        }
        return indexes
    }
}
