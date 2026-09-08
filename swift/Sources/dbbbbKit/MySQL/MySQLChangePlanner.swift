import Foundation
import dbbbbCore

/// One ordered column/value pair of a row snapshot. Ordering matters: it is
/// the catalog order captured at metadata time and determines parameter order.
public typealias MySQLFieldEntry = (column: String, value: DisplayValue)

/// A parameterized SQL statement plus its bind values. Values are never
/// interpolated into the text.
public struct MySQLParameterizedPlan: Sendable, Equatable {
    public let text: String
    public let values: [DisplayValue]
    public init(text: String, values: [DisplayValue]) {
        self.text = text
        self.values = values
    }
}

/// Column metadata for a change target, validated at metadata time.
public struct MySQLChangeTableMetadata: Sendable, Equatable {
    public let columns: [String]
    public let columnTypes: [String: String]
    public let primaryKey: [String]
    public init(columns: [String], columnTypes: [String: String], primaryKey: [String]) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.primaryKey = primaryKey
    }
}

/// Errors raised while planning a single-row change. These are review-facing
/// messages; they never contain credentials.
public struct MySQLChangePlanError: dbbbbError, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var userMessage: String { reason }
}

/// Pure planner for safe single-row MySQL changes (optimistic concurrency).
/// Mirrors `PostgresChangePlanner` — itself ported from
/// `src/main/editing/change-planner.ts` — with MySQL semantics: every
/// `UPDATE`/`DELETE` is parameterized and matches the primary key plus *all*
/// original column values with the NULL-safe `<=>` operator. String-family
/// columns are matched byte-for-byte through the `BINARY` cast, because the
/// column's own collation (default `utf8mb4_0900_ai_ci`) would equate
/// case/accent/trailing-space variants and miss a concurrent change. MySQL
/// has no `RETURNING`; the adapter detects conflicts through the OK packet's
/// affected-row count (zero rows = the row changed or vanished underneath
/// the edit).
public enum MySQLChangePlanner {
    /// JS-era prototype-pollution guards; kept because record keys still come
    /// from a UI round-trip and are never valid column choices for us.
    public static let dangerousFieldNames: Set<String> = ["__proto__", "constructor", "prototype"]

    /// Types whose wire values cannot round-trip losslessly through an edit, so
    /// single-row changes refuse them at metadata time instead of misreporting
    /// an optimistic-concurrency conflict later. `bit` crosses as raw bytes and
    /// the spatial family crosses as opaque WKB; neither can be bound back from
    /// the displayed value. Everything else crosses as the server's own text
    /// rendering (or a number/bool), which parses back exactly — including
    /// `json`, which MySQL normalizes on write like PostgreSQL's `jsonb`.
    public static let nonRoundTrippingTypeNames: Set<String> = [
        "bit",
        "geometry", "point", "linestring", "polygon",
        "multipoint", "multilinestring", "multipolygon", "geometrycollection",
    ]

    /// Lowercased `DATA_TYPE` names whose comparisons follow the column
    /// collation. Under a case/accent-insensitive collation a concurrent
    /// transaction that only changes letter case, accents, or trailing
    /// spaces would stay invisible to the optimistic lock, so these columns
    /// are compared byte-for-byte via the `BINARY` cast instead. The binary
    /// family (blob/binary) already compares bytes, and fixed-scale decimal
    /// stores a canonical rendering per value, so neither needs the cast.
    public static let byteComparedTypeNames: Set<String> = [
        "char", "varchar",
        "tinytext", "text", "mediumtext", "longtext",
        "enum", "set",
    ]

    /// Introspection query for the change-target metadata (used by the editing
    /// capability; the planner itself is offline). Generated columns are
    /// excluded (same `GENERATION_EXPRESSION` filter as the import milestone);
    /// the server rejects any remaining privilege violation on write.
    public static let listTableChangeColumnsSQL = """
        SELECT
          c.COLUMN_NAME,
          c.DATA_TYPE,
          COALESCE(k.ORDINAL_POSITION, 0) AS primary_key_ordinal
        FROM information_schema.COLUMNS AS c
        LEFT JOIN information_schema.KEY_COLUMN_USAGE AS k
          ON k.TABLE_SCHEMA = c.TABLE_SCHEMA
          AND k.TABLE_NAME = c.TABLE_NAME
          AND k.COLUMN_NAME = c.COLUMN_NAME
          AND k.CONSTRAINT_NAME = 'PRIMARY'
        WHERE c.TABLE_SCHEMA = ?
          AND c.TABLE_NAME = ?
          AND c.GENERATION_EXPRESSION = ''
        ORDER BY c.ORDINAL_POSITION
        """

    // MARK: - Metadata validation

    /// Validates and folds raw introspection rows `(COLUMN_NAME, DATA_TYPE,
    /// primary_key_ordinal)` into change-target metadata.
    public static func changeTableMetadata(
        rows: [(name: String, dataType: String, primaryKeyOrdinal: Int)]
    ) throws -> MySQLChangeTableMetadata {
        guard !rows.isEmpty else {
            throw MySQLChangePlanError(
                reason: "MySQL change target no longer has editable table columns.")
        }

        var columns: [String] = []
        var columnNames: Set<String> = []
        var columnTypes: [String: String] = [:]
        var primaryKeyEntries: [(column: String, ordinal: Int)] = []
        var primaryKeyOrdinals: Set<Int> = []

        for row in rows {
            let dataType = row.dataType.lowercased()
            guard !row.name.isEmpty,
                  !row.dataType.isEmpty,
                  row.primaryKeyOrdinal >= 0,
                  !columnNames.contains(row.name)
            else {
                throw MySQLChangePlanError(
                    reason: "MySQL returned invalid table-change metadata.")
            }
            if nonRoundTrippingTypeNames.contains(dataType) {
                throw MySQLChangePlanError(
                    reason: "MySQL row changes cannot edit column \(row.name): "
                        + "type \(dataType) values do not round-trip losslessly.")
            }
            columns.append(row.name)
            columnNames.insert(row.name)
            columnTypes[row.name] = dataType
            if row.primaryKeyOrdinal > 0 {
                guard !primaryKeyOrdinals.contains(row.primaryKeyOrdinal) else {
                    throw MySQLChangePlanError(
                        reason: "MySQL returned invalid primary-key metadata.")
                }
                primaryKeyOrdinals.insert(row.primaryKeyOrdinal)
                primaryKeyEntries.append((row.name, row.primaryKeyOrdinal))
            }
        }

        primaryKeyEntries.sort { $0.ordinal < $1.ordinal }
        guard !primaryKeyEntries.isEmpty else {
            throw MySQLChangePlanError(
                reason: "MySQL single-row changes require a table primary key.")
        }
        for (index, entry) in primaryKeyEntries.enumerated() where entry.ordinal != index + 1 {
            throw MySQLChangePlanError(
                reason: "MySQL returned invalid primary-key ordering metadata.")
        }

        return MySQLChangeTableMetadata(
            columns: columns,
            columnTypes: columnTypes,
            primaryKey: primaryKeyEntries.map(\.column))
    }

    // MARK: - Identifier quoting

    /// Backtick-quote a MySQL identifier. Rejects empty names and NUL bytes.
    public static func quoteIdentifier(_ identifier: String) throws -> String {
        guard !identifier.isEmpty, !identifier.contains("\0") else {
            throw MySQLChangePlanError(
                reason: "MySQL identifiers must be non-empty strings without null bytes.")
        }
        return "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    // MARK: - Snapshot validation

    private static func validatedEntries(
        _ entries: [MySQLFieldEntry], label: String
    ) throws -> [MySQLFieldEntry] {
        var seen: Set<String> = []
        for (column, _) in entries {
            guard !column.isEmpty, !column.contains("\0") else {
                throw MySQLChangePlanError(reason: "\(label) contains an invalid field name.")
            }
            if dangerousFieldNames.contains(column) {
                throw MySQLChangePlanError(
                    reason: "\(label) contains the dangerous key \(column).")
            }
            guard seen.insert(column).inserted else {
                throw MySQLChangePlanError(reason: "\(label) contains a duplicate field name.")
            }
        }
        return entries
    }

    private struct Target {
        let qualifiedTable: String
        let primaryKey: [MySQLFieldEntry]
        let original: [MySQLFieldEntry]
    }

    private static func target(
        database: String,
        table: String,
        primaryKey: [MySQLFieldEntry],
        original: [MySQLFieldEntry]
    ) throws -> Target {
        let qualifiedTable = try "\(quoteIdentifier(database)).\(quoteIdentifier(table))"
        let key = try validatedEntries(primaryKey, label: "MySQL primary key")
        let originalEntries = try validatedEntries(original, label: "MySQL original patch")

        guard !key.isEmpty else {
            throw MySQLChangePlanError(
                reason: "A MySQL single-row change requires at least one primary-key column.")
        }
        guard !originalEntries.isEmpty else {
            throw MySQLChangePlanError(
                reason: "A MySQL single-row change requires original values for concurrency checks.")
        }

        let keyValues = Dictionary(key.map { ($0.column, $0.value) }) { first, _ in first }
        for (column, value) in key where value == .null {
            throw MySQLChangePlanError(
                reason: "MySQL primary-key column \(column) cannot be null.")
        }
        for (column, value) in originalEntries {
            if let keyValue = keyValues[column], keyValue != value {
                throw MySQLChangePlanError(
                    reason: "MySQL original value for primary-key column \(column) is inconsistent.")
            }
        }

        return Target(qualifiedTable: qualifiedTable, primaryKey: key, original: originalEntries)
    }

    private static func appendWhere(
        values: inout [DisplayValue],
        columnTypes: [String: String],
        primaryKey: [MySQLFieldEntry],
        original: [MySQLFieldEntry]
    ) throws -> String {
        var conditions: [String] = []
        let keyColumns = Set(primaryKey.map(\.column))

        for (column, value) in primaryKey {
            values.append(value)
            try conditions.append(equality(column: column, columnTypes: columnTypes))
        }
        for (column, value) in original where !keyColumns.contains(column) {
            values.append(value)
            try conditions.append(equality(column: column, columnTypes: columnTypes))
        }
        return conditions.joined(separator: "\n  AND ")
    }

    /// The NULL-safe optimistic-lock predicate for one column. String-family
    /// columns compare bytes (`BINARY` on both sides; `<=>` stays NULL-safe
    /// under the cast); everything else compares natively.
    private static func equality(column: String, columnTypes: [String: String]) throws -> String {
        let quoted = try quoteIdentifier(column)
        if let type = columnTypes[column], byteComparedTypeNames.contains(type) {
            return "BINARY \(quoted) <=> BINARY ?"
        }
        return "\(quoted) <=> ?"
    }

    // MARK: - Plans

    /// Plans one optimistic row update. `original` and `current` must contain
    /// the same columns; only values that actually changed are assigned.
    /// `columnTypes` (lowercased `DATA_TYPE` per column, from the change
    /// metadata) selects byte-level matching for string-family columns.
    public static func planUpdate(
        database: String,
        table: String,
        columnTypes: [String: String],
        primaryKey: [MySQLFieldEntry],
        original: [MySQLFieldEntry],
        current: [MySQLFieldEntry]
    ) throws -> MySQLParameterizedPlan {
        let target = try target(
            database: database, table: table, primaryKey: primaryKey, original: original)
        let currentEntries = try validatedEntries(current, label: "MySQL current patch")
        let originalValues = Dictionary(target.original.map { ($0.column, $0.value) }) { first, _ in first }

        guard currentEntries.count == target.original.count,
              currentEntries.allSatisfy({ originalValues[$0.column] != nil })
        else {
            throw MySQLChangePlanError(
                reason: "MySQL original and current patches must contain the same columns.")
        }

        let keyColumns = Set(target.primaryKey.map(\.column))
        let changed = currentEntries.filter { originalValues[$0.column]! != $0.value }
        guard !changed.isEmpty else {
            throw MySQLChangePlanError(
                reason: "A MySQL update patch must contain at least one changed value.")
        }
        if let changedKey = changed.first(where: { keyColumns.contains($0.column) }) {
            throw MySQLChangePlanError(
                reason: "MySQL primary-key column \(changedKey.column) cannot be edited.")
        }

        var values: [DisplayValue] = []
        var assignments: [String] = []
        for (column, value) in changed {
            values.append(value)
            try assignments.append("\(quoteIdentifier(column)) = ?")
        }
        var whereValues = values
        let whereClause = try appendWhere(
            values: &whereValues, columnTypes: columnTypes,
            primaryKey: target.primaryKey, original: target.original)

        return MySQLParameterizedPlan(
            text: [
                "UPDATE \(target.qualifiedTable)",
                "SET \(assignments.joined(separator: ",\n    "))",
                "WHERE \(whereClause)",
            ].joined(separator: "\n"),
            values: whereValues)
    }

    /// Plans one optimistic row delete without executing it. `columnTypes`
    /// selects byte-level matching for string-family columns, as in
    /// `planUpdate`.
    public static func planDelete(
        database: String,
        table: String,
        columnTypes: [String: String],
        primaryKey: [MySQLFieldEntry],
        original: [MySQLFieldEntry]
    ) throws -> MySQLParameterizedPlan {
        let target = try target(
            database: database, table: table, primaryKey: primaryKey, original: original)
        var values: [DisplayValue] = []
        let whereClause = try appendWhere(
            values: &values, columnTypes: columnTypes,
            primaryKey: target.primaryKey, original: target.original)

        return MySQLParameterizedPlan(
            text: [
                "DELETE FROM \(target.qualifiedTable)",
                "WHERE \(whereClause)",
            ].joined(separator: "\n"),
            values: values)
    }

    /// Plans one row insert. There is no optimistic lock (the row does not
    /// exist yet); the same field-name validation as updates applies. Values
    /// bind in entry order; omitted columns take their server default, and an
    /// empty entry list becomes `INSERT … () VALUES ()` (all defaults).
    /// MySQL has no `RETURNING`; the adapter checks the OK packet's
    /// affected-row count is exactly 1.
    public static func planInsert(
        database: String,
        table: String,
        entries: [MySQLFieldEntry]
    ) throws -> MySQLParameterizedPlan {
        let qualifiedTable = try "\(quoteIdentifier(database)).\(quoteIdentifier(table))"
        let validated = try validatedEntries(entries, label: "MySQL insert values")

        guard !validated.isEmpty else {
            return MySQLParameterizedPlan(
                text: "INSERT INTO \(qualifiedTable) () VALUES ()",
                values: [])
        }
        var columns: [String] = []
        for (column, _) in validated {
            try columns.append(quoteIdentifier(column))
        }
        return MySQLParameterizedPlan(
            text: "INSERT INTO \(qualifiedTable) (\(columns.joined(separator: ", ")))\n"
                + "VALUES (\(validated.map { _ in "?" }.joined(separator: ", ")))",
            values: validated.map(\.value))
    }
}
