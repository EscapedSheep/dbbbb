import Foundation
import dbbbbCore

/// Pure catalog queries + row folding for MySQL structured-schema
/// introspection ("View Schema"): `information_schema.COLUMNS` (PK ordinal
/// joined from `KEY_COLUMN_USAGE`), `STATISTICS` for indexes, and the
/// `MySQLForeignKeyPlanner` KEY_COLUMN_USAGE query widened to a whole scope.
/// Names always cross as `?` binds, never interpolated.
enum MySQLSchemaPlanner {
    /// (name, display type, nullable flag, primary-key ordinal) rows for one
    /// table, ordered by catalog position. `COLUMN_TYPE` carries the full
    /// declaration ("int unsigned", "varchar(255)"); the PK ordinal is 0 for
    /// non-key columns.
    static let listColumnsSQL = """
        SELECT c.COLUMN_NAME,
               c.COLUMN_TYPE,
               c.IS_NULLABLE,
               COALESCE(k.ORDINAL_POSITION, 0) AS PK_ORDINAL
        FROM information_schema.COLUMNS AS c
        LEFT JOIN information_schema.KEY_COLUMN_USAGE AS k
          ON k.TABLE_SCHEMA = c.TABLE_SCHEMA
         AND k.TABLE_NAME = c.TABLE_NAME
         AND k.COLUMN_NAME = c.COLUMN_NAME
         AND k.CONSTRAINT_NAME = 'PRIMARY'
        WHERE c.TABLE_SCHEMA = ?
          AND c.TABLE_NAME = ?
        ORDER BY c.ORDINAL_POSITION
        """

    /// (index name, non-unique flag, column) rows for one table, ordered by
    /// index name then position within the index. The PRIMARY index is
    /// included — it is an index the schema viewer should show.
    static let listIndexesSQL = """
        SELECT INDEX_NAME,
               NON_UNIQUE,
               COLUMN_NAME
        FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = ?
          AND TABLE_NAME = ?
        ORDER BY INDEX_NAME, SEQ_IN_INDEX
        """

    /// (source schema/table, constraint, column, referenced
    /// schema/table/column) rows for one database — the
    /// `MySQLForeignKeyPlanner.listForeignKeysSQL` shape widened with the
    /// source relation and without its table filter, ordered so each table's
    /// constraints arrive grouped in ordinal order.
    static let listAllForeignKeysSQL = """
        SELECT TABLE_SCHEMA,
               TABLE_NAME,
               CONSTRAINT_NAME,
               COLUMN_NAME,
               REFERENCED_TABLE_SCHEMA,
               REFERENCED_TABLE_NAME,
               REFERENCED_COLUMN_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = ?
          AND CONSTRAINT_NAME <> 'PRIMARY'
          AND REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
        """

    /// Server-wide variant (database-less connections): every non-system
    /// schema, unbound like `listServerWideObjects`.
    static let listServerWideForeignKeysSQL = """
        SELECT TABLE_SCHEMA,
               TABLE_NAME,
               CONSTRAINT_NAME,
               COLUMN_NAME,
               REFERENCED_TABLE_SCHEMA,
               REFERENCED_TABLE_NAME,
               REFERENCED_COLUMN_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
          AND CONSTRAINT_NAME <> 'PRIMARY'
          AND REFERENCED_TABLE_NAME IS NOT NULL
        ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
        """

    /// Folds (already catalog-ordered) rows into column schemas. Malformed
    /// rows fail closed: empty names, unknown nullable flags, and negative
    /// ordinals refuse the result.
    static func columns(
        rows: [(name: String, dataType: String, nullable: String, primaryKeyOrdinal: Int)]
    ) throws -> [ColumnSchema] {
        var seen: Set<String> = []
        var columns: [ColumnSchema] = []
        for row in rows {
            guard !row.name.isEmpty, row.primaryKeyOrdinal >= 0,
                  seen.insert(row.name).inserted
            else {
                throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
            }
            let nullable: Bool
            switch row.nullable {
            case "YES": nullable = true
            case "NO": nullable = false
            default:
                throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
            }
            columns.append(ColumnSchema(
                name: row.name,
                dataType: row.dataType,
                nullable: nullable,
                primaryKeyOrdinal: row.primaryKeyOrdinal))
        }
        return columns
    }

    /// Folds (index-name, then position ordered) rows into grouped indexes.
    /// `nonUnique` is the STATISTICS NON_UNIQUE flag as text ("0"/"1").
    static func indexes(
        rows: [(name: String, nonUnique: String, column: String)]
    ) throws -> [IndexSchema] {
        var order: [String] = []
        var grouped: [String: (isUnique: Bool, columns: [String])] = [:]
        for row in rows {
            guard !row.name.isEmpty, !row.column.isEmpty,
                  row.nonUnique == "0" || row.nonUnique == "1"
            else {
                throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
            }
            let isUnique = row.nonUnique == "0"
            if grouped[row.name] == nil {
                order.append(row.name)
                grouped[row.name] = (isUnique, [])
            }
            guard var entry = grouped[row.name],
                  entry.isUnique == isUnique,
                  !entry.columns.contains(row.column)
            else {
                throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
            }
            entry.columns.append(row.column)
            grouped[row.name] = entry
        }
        return order.map { name in
            let entry = grouped[name]!
            return IndexSchema(name: name, columns: entry.columns, isUnique: entry.isUnique)
        }
    }

    /// Folds rows (grouped by source table, constraint, ordinal) into
    /// scope-wide edges: each table's rows replay through the single-table
    /// `MySQLForeignKeyPlanner` folding, so multi-column pairing and
    /// malformed-row handling stay identical.
    static func allForeignKeys(
        rows: [(schema: String, table: String, constraint: String, column: String,
                referencedSchema: String, referencedTable: String, referencedColumn: String)]
    ) throws -> [TableRelation] {
        var order: [(schema: String, table: String)] = []
        var grouped: [String: [(constraint: String, column: String, referencedSchema: String,
                                referencedTable: String, referencedColumn: String)]] = [:]
        for row in rows {
            guard !row.schema.isEmpty, !row.table.isEmpty else {
                throw MySQLAdapterError.failure("MySQL returned invalid foreign-key metadata.")
            }
            let key = "\(row.schema)\u{1F}\(row.table)"
            if grouped[key] == nil {
                order.append((row.schema, row.table))
                grouped[key] = []
            }
            grouped[key]?.append((row.constraint, row.column, row.referencedSchema,
                                  row.referencedTable, row.referencedColumn))
        }

        var relations: [TableRelation] = []
        for source in order {
            let key = "\(source.schema)\u{1F}\(source.table)"
            let keys = try MySQLForeignKeyPlanner.foreignKeys(rows: grouped[key] ?? [])
            let tableRef = MySQLObjectRef(kind: .table, database: source.schema, name: source.table)
            let schemaRef = MySQLObjectRef(kind: .database, database: source.schema, name: nil)
            let object = DatabaseObject(
                id: tableRef.id,
                parentID: schemaRef.id,
                name: source.table,
                kind: .table)
            relations.append(contentsOf: keys.map { TableRelation(object: object, foreignKey: $0) })
        }
        return relations
    }
}
