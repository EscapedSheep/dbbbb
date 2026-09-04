import Foundation
import dbbbbCore

/// One ordered column/value pair of a row snapshot. Ordering matters: it is
/// the catalog order captured at metadata time and determines parameter order.
public typealias SQLiteFieldEntry = (column: String, value: DisplayValue)

/// A parameterized SQL statement plus its bind values. Values are never
/// interpolated into the text.
public struct SQLiteParameterizedPlan: Sendable, Equatable {
    public let text: String
    public let values: [DisplayValue]
    public init(text: String, values: [DisplayValue]) {
        self.text = text
        self.values = values
    }
}

/// Column metadata for a change target, validated at metadata time.
public struct SQLiteChangeTableMetadata: Sendable, Equatable {
    public let columns: [String]
    /// Declared column types, uppercased (e.g. `INTEGER`, `VARCHAR(20)`).
    /// Used for the numeric storage-class decision at bind time.
    public let columnTypes: [String: String]
    public let primaryKey: [String]
    public init(columns: [String], columnTypes: [String: String], primaryKey: [String]) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.primaryKey = primaryKey
    }
}

/// Errors raised while planning a single-row change. These are review-facing
/// messages; they never contain the database file path.
public struct SQLiteChangePlanError: dbbbbError, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var userMessage: String { reason }
}

/// Pure planner for safe single-row SQLite changes (optimistic concurrency).
/// Mirrors `PostgresChangePlanner` with SQLite semantics: every
/// `UPDATE`/`DELETE` is parameterized and matches the primary key plus *all*
/// original column values with the NULL-safe `IS` operator. TEXT-affinity
/// columns match with an explicit `COLLATE BINARY` on the bound value,
/// because the column's declared collation (`NOCASE`/`RTRIM`) would equate
/// case/accent/trailing-space variants and miss a concurrent change. The
/// adapter detects conflicts through `changes()`: zero changed rows means
/// the row changed or vanished underneath the edit.
///
/// Unlike PostgreSQL/MySQL there is no type-refusal list: SQLite values are
/// one of four storage classes (INTEGER/REAL/TEXT/BLOB), and every display
/// value binds back into its own class, so all column types round-trip.
public enum SQLiteChangePlanner {
    /// JS-era prototype-pollution guards; kept because record keys still come
    /// from a UI round-trip and are never valid column choices for us.
    public static let dangerousFieldNames: Set<String> = ["__proto__", "constructor", "prototype"]

    /// Introspection query for the change-target metadata (used by the editing
    /// capability; the planner itself is offline). Hidden (virtual-table) and
    /// generated columns are excluded via `pragma_table_xinfo`'s hidden flag —
    /// the same filter the import milestone uses. `pk` is the 1-based position
    /// of the column in the primary key, or 0 when not part of it.
    public static let listTableChangeColumnsSQL = """
        SELECT name, type, pk
        FROM pragma_table_xinfo(?)
        WHERE hidden = 0
        ORDER BY cid
        """

    // MARK: - Metadata validation

    /// Validates and folds raw introspection rows `(name, declared_type,
    /// pk_ordinal)` into change-target metadata.
    public static func changeTableMetadata(
        rows: [(name: String, declaredType: String, primaryKeyOrdinal: Int)]
    ) throws -> SQLiteChangeTableMetadata {
        guard !rows.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "SQLite change target no longer has editable table columns.")
        }

        var columns: [String] = []
        var columnNames: Set<String> = []
        var columnTypes: [String: String] = [:]
        var primaryKeyEntries: [(column: String, ordinal: Int)] = []
        var primaryKeyOrdinals: Set<Int> = []

        for row in rows {
            guard !row.name.isEmpty,
                  row.primaryKeyOrdinal >= 0,
                  !columnNames.contains(row.name)
            else {
                throw SQLiteChangePlanError(
                    reason: "SQLite returned invalid table-change metadata.")
            }
            columns.append(row.name)
            columnNames.insert(row.name)
            columnTypes[row.name] = row.declaredType.uppercased()
            if row.primaryKeyOrdinal > 0 {
                guard !primaryKeyOrdinals.contains(row.primaryKeyOrdinal) else {
                    throw SQLiteChangePlanError(
                        reason: "SQLite returned invalid primary-key metadata.")
                }
                primaryKeyOrdinals.insert(row.primaryKeyOrdinal)
                primaryKeyEntries.append((row.name, row.primaryKeyOrdinal))
            }
        }

        primaryKeyEntries.sort { $0.ordinal < $1.ordinal }
        guard !primaryKeyEntries.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "SQLite single-row changes require a table primary key.")
        }
        for (index, entry) in primaryKeyEntries.enumerated() where entry.ordinal != index + 1 {
            throw SQLiteChangePlanError(
                reason: "SQLite returned invalid primary-key ordering metadata.")
        }

        return SQLiteChangeTableMetadata(
            columns: columns,
            columnTypes: columnTypes,
            primaryKey: primaryKeyEntries.map(\.column))
    }

    // MARK: - Identifier quoting

    /// Double-quote a SQLite identifier. Rejects empty names and NUL bytes.
    public static func quoteIdentifier(_ identifier: String) throws -> String {
        guard !identifier.isEmpty, !identifier.contains("\0") else {
            throw SQLiteChangePlanError(
                reason: "SQLite identifiers must be non-empty strings without null bytes.")
        }
        return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Snapshot validation

    private static func validatedEntries(
        _ entries: [SQLiteFieldEntry], label: String
    ) throws -> [SQLiteFieldEntry] {
        var seen: Set<String> = []
        for (column, _) in entries {
            guard !column.isEmpty, !column.contains("\0") else {
                throw SQLiteChangePlanError(reason: "\(label) contains an invalid field name.")
            }
            if dangerousFieldNames.contains(column) {
                throw SQLiteChangePlanError(
                    reason: "\(label) contains the dangerous key \(column).")
            }
            guard seen.insert(column).inserted else {
                throw SQLiteChangePlanError(reason: "\(label) contains a duplicate field name.")
            }
        }
        return entries
    }

    private struct Target {
        let qualifiedTable: String
        let primaryKey: [SQLiteFieldEntry]
        let original: [SQLiteFieldEntry]
    }

    private static func target(
        table: String,
        primaryKey: [SQLiteFieldEntry],
        original: [SQLiteFieldEntry]
    ) throws -> Target {
        let qualifiedTable = try quoteIdentifier(table)
        let key = try validatedEntries(primaryKey, label: "SQLite primary key")
        let originalEntries = try validatedEntries(original, label: "SQLite original patch")

        guard !key.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "A SQLite single-row change requires at least one primary-key column.")
        }
        guard !originalEntries.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "A SQLite single-row change requires original values for concurrency checks.")
        }

        let keyValues = Dictionary(key.map { ($0.column, $0.value) }) { first, _ in first }
        for (column, value) in key where value == .null {
            throw SQLiteChangePlanError(
                reason: "SQLite primary-key column \(column) cannot be null.")
        }
        for (column, value) in originalEntries {
            if let keyValue = keyValues[column], keyValue != value {
                throw SQLiteChangePlanError(
                    reason: "SQLite original value for primary-key column \(column) is inconsistent.")
            }
        }

        return Target(qualifiedTable: qualifiedTable, primaryKey: key, original: originalEntries)
    }

    private static func appendWhere(
        values: inout [DisplayValue],
        columnTypes: [String: String],
        primaryKey: [SQLiteFieldEntry],
        original: [SQLiteFieldEntry]
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

    /// The NULL-safe optimistic-lock predicate for one column. TEXT-affinity
    /// columns compare bytes via an explicit `COLLATE BINARY` on the bound
    /// value, overriding the column's declared collation (`IS` stays
    /// NULL-safe); other affinities compare storage classes exactly already.
    private static func equality(column: String, columnTypes: [String: String]) throws -> String {
        let quoted = try quoteIdentifier(column)
        if let type = columnTypes[column], isTextAffinity(type) {
            return "\(quoted) IS ? COLLATE BINARY"
        }
        return "\(quoted) IS ?"
    }

    /// SQLite's TEXT-affinity rule on the uppercased declared type: INTEGER
    /// affinity wins when the type contains INT, otherwise CHAR/CLOB/TEXT
    /// make it TEXT affinity.
    private static func isTextAffinity(_ declaredType: String) -> Bool {
        !declaredType.contains("INT")
            && (declaredType.contains("CHAR")
                || declaredType.contains("CLOB")
                || declaredType.contains("TEXT"))
    }

    // MARK: - Plans

    /// Plans one optimistic row update. `original` and `current` must contain
    /// the same columns; only values that actually changed are assigned.
    /// `columnTypes` (uppercased declared types, from the change metadata)
    /// selects byte-level matching for TEXT-affinity columns.
    public static func planUpdate(
        table: String,
        columnTypes: [String: String],
        primaryKey: [SQLiteFieldEntry],
        original: [SQLiteFieldEntry],
        current: [SQLiteFieldEntry]
    ) throws -> SQLiteParameterizedPlan {
        let target = try target(table: table, primaryKey: primaryKey, original: original)
        let currentEntries = try validatedEntries(current, label: "SQLite current patch")
        let originalValues = Dictionary(target.original.map { ($0.column, $0.value) }) { first, _ in first }

        guard currentEntries.count == target.original.count,
              currentEntries.allSatisfy({ originalValues[$0.column] != nil })
        else {
            throw SQLiteChangePlanError(
                reason: "SQLite original and current patches must contain the same columns.")
        }

        let keyColumns = Set(target.primaryKey.map(\.column))
        let changed = currentEntries.filter { originalValues[$0.column]! != $0.value }
        guard !changed.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "A SQLite update patch must contain at least one changed value.")
        }
        if let changedKey = changed.first(where: { keyColumns.contains($0.column) }) {
            throw SQLiteChangePlanError(
                reason: "SQLite primary-key column \(changedKey.column) cannot be edited.")
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

        return SQLiteParameterizedPlan(
            text: [
                "UPDATE \(target.qualifiedTable)",
                "SET \(assignments.joined(separator: ",\n    "))",
                "WHERE \(whereClause)",
            ].joined(separator: "\n"),
            values: whereValues)
    }

    /// Plans one optimistic row delete without executing it. `columnTypes`
    /// selects byte-level matching for TEXT-affinity columns, as in
    /// `planUpdate`.
    public static func planDelete(
        table: String,
        columnTypes: [String: String],
        primaryKey: [SQLiteFieldEntry],
        original: [SQLiteFieldEntry]
    ) throws -> SQLiteParameterizedPlan {
        let target = try target(table: table, primaryKey: primaryKey, original: original)
        var values: [DisplayValue] = []
        let whereClause = try appendWhere(
            values: &values, columnTypes: columnTypes,
            primaryKey: target.primaryKey, original: target.original)

        return SQLiteParameterizedPlan(
            text: [
                "DELETE FROM \(target.qualifiedTable)",
                "WHERE \(whereClause)",
            ].joined(separator: "\n"),
            values: values)
    }
}
