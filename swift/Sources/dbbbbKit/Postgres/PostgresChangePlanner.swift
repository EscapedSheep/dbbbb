import Foundation
import dbbbbCore

/// One ordered column/value pair of a row snapshot. Ordering matters: it is
/// the catalog order captured at metadata time and determines parameter order.
public typealias PostgresFieldEntry = (column: String, value: DisplayValue)

/// A parameterized SQL statement plus its bind values. Values are never
/// interpolated into the text.
public struct PostgresParameterizedPlan: Sendable, Equatable {
    public let text: String
    public let values: [DisplayValue]
    public init(text: String, values: [DisplayValue]) {
        self.text = text
        self.values = values
    }
}

/// Column metadata for a change target, validated at metadata time.
public struct PostgresChangeTableMetadata: Sendable, Equatable {
    public let columns: [String]
    public let columnTypeOIDs: [String: Int]
    public let primaryKey: [String]
    public init(columns: [String], columnTypeOIDs: [String: Int], primaryKey: [String]) {
        self.columns = columns
        self.columnTypeOIDs = columnTypeOIDs
        self.primaryKey = primaryKey
    }
}

/// Errors raised while planning a single-row change. These are review-facing
/// messages; they never contain credentials.
public struct PostgresChangePlanError: dbbbbError, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var userMessage: String { reason }
}

/// Pure planner for safe single-row PostgreSQL changes (optimistic
/// concurrency). Ported from `src/main/editing/change-planner.ts`: every
/// `UPDATE`/`DELETE` is parameterized, matches the primary key plus *all*
/// original column values with `IS NOT DISTINCT FROM`, and returns the changed
/// row via `RETURNING *`. Text-family and `numeric` columns are matched
/// byte-for-byte on their canonical text (`convert_to(..., 'UTF8')` on both
/// sides, keeping the NULL-safe semantics): the column collation (a
/// nondeterministic ICU one equates case/accent variants) and `numeric`
/// value equality (which ignores display scale, `1.10` vs `1.1000`) would
/// otherwise hide a concurrent change from the lock.
public enum PostgresChangePlanner {
    /// JS-era prototype-pollution guards; kept because record keys still come
    /// from a UI round-trip and are never valid column choices for us.
    public static let dangerousFieldNames: Set<String> = ["__proto__", "constructor", "prototype"]

    /// Types whose wire values cannot round-trip losslessly through an edit, so
    /// single-row changes refuse them at metadata time instead of misreporting
    /// an optimistic-concurrency conflict later. `json` (unlike `jsonb`) does
    /// not preserve key order/duplicates, `interval` and `money` are
    /// session-dependent, and range/multirange bounds do not survive a text
    /// round-trip unchanged.
    public static let nonRoundTrippingTypeNames: Set<String> = [
        "json", "interval", "money",
        "int4range", "int8range", "numrange", "tsrange", "tstzrange", "daterange",
        "int4multirange", "int8multirange", "nummultirange",
        "tsmultirange", "tstzmultirange", "datemultirange",
    ]

    /// Type OIDs whose optimistic-lock predicates compare the canonical text
    /// byte-for-byte instead of using native equality: the text family
    /// (19 `name`, 25 `text`, 1042 `bpchar`, 1043 `varchar`), whose equality
    /// follows the column collation (nondeterministic ICU collations equate
    /// case/accent variants), and 1700 `numeric`, whose value equality
    /// ignores display scale (`1.10` vs `1.1000` are stored distinctly but
    /// compare equal). Arrays, domains, and extension types keep native
    /// equality — their renderings are not guaranteed to round-trip.
    public static let byteComparedTypeOIDs: Set<Int> = [19, 25, 1042, 1043, 1700]

    /// Introspection query for the change-target metadata (used by the editing
    /// capability; the planner itself is offline). Columns without UPDATE
    /// privilege are excluded, as are generated and identity columns — a table
    /// containing them is refused wholesale at mapping time, matching the
    /// MySQL/SQLite engines. DELETE is table-level (column-level DELETE
    /// privileges do not exist — `has_column_privilege(..., 'DELETE')` errors
    /// with sqlState 22023 on a live server), so it is checked per table.
    public static let listTableChangeColumnsSQL = """
        SELECT
          a.attname,
          a.atttypid,
          t.typname,
          COALESCE(pk.primary_key_ordinal, 0) AS primary_key_ordinal
        FROM pg_catalog.pg_attribute AS a
        JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_type AS t ON t.oid = a.atttypid
        LEFT JOIN LATERAL (
          SELECT key.ordinality::integer AS primary_key_ordinal
          FROM pg_catalog.pg_index AS i
          CROSS JOIN LATERAL pg_catalog.unnest(i.indkey)
            WITH ORDINALITY AS key(attnum, ordinality)
          WHERE i.indrelid = c.oid
            AND i.indisprimary
            AND key.attnum = a.attnum
            AND key.ordinality <= i.indnkeyatts
        ) AS pk ON TRUE
        WHERE n.nspname = $1
          AND c.relname = $2
          AND c.relkind IN ('r', 'p', 'f')
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attgenerated = ''
          AND a.attidentity = ''
          AND pg_catalog.has_column_privilege(c.oid, a.attname, 'UPDATE')
          AND pg_catalog.has_table_privilege(c.oid, 'DELETE')
        ORDER BY a.attnum
        """

    // MARK: - Metadata validation

    /// Validates and folds raw introspection rows `(attname, atttypid,
    /// typname, primary_key_ordinal)` into change-target metadata.
    public static func changeTableMetadata(
        rows: [(name: String, typeOID: Int, typeName: String, primaryKeyOrdinal: Int)]
    ) throws -> PostgresChangeTableMetadata {
        guard !rows.isEmpty else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL change target no longer has editable table columns.")
        }

        var columns: [String] = []
        var columnNames: Set<String> = []
        var columnTypeOIDs: [String: Int] = [:]
        var primaryKeyEntries: [(column: String, ordinal: Int)] = []
        var primaryKeyOrdinals: Set<Int> = []

        for row in rows {
            guard !row.name.isEmpty,
                  row.typeOID > 0,
                  !row.typeName.isEmpty,
                  row.primaryKeyOrdinal >= 0,
                  !columnNames.contains(row.name)
            else {
                throw PostgresChangePlanError(
                    reason: "PostgreSQL returned invalid table-change metadata.")
            }
            // Array element types share the same round-trip limits as their base type.
            let baseTypeName = row.typeName.hasPrefix("_") ? String(row.typeName.dropFirst()) : row.typeName
            if nonRoundTrippingTypeNames.contains(baseTypeName) {
                throw PostgresChangePlanError(
                    reason: "PostgreSQL row changes cannot edit column \(row.name): "
                        + "type \(row.typeName) values do not round-trip losslessly.")
            }
            columns.append(row.name)
            columnNames.insert(row.name)
            columnTypeOIDs[row.name] = row.typeOID
            if row.primaryKeyOrdinal > 0 {
                guard !primaryKeyOrdinals.contains(row.primaryKeyOrdinal) else {
                    throw PostgresChangePlanError(
                        reason: "PostgreSQL returned invalid primary-key metadata.")
                }
                primaryKeyOrdinals.insert(row.primaryKeyOrdinal)
                primaryKeyEntries.append((row.name, row.primaryKeyOrdinal))
            }
        }

        primaryKeyEntries.sort { $0.ordinal < $1.ordinal }
        guard !primaryKeyEntries.isEmpty else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL single-row changes require a table primary key.")
        }
        for (index, entry) in primaryKeyEntries.enumerated() where entry.ordinal != index + 1 {
            throw PostgresChangePlanError(
                reason: "PostgreSQL returned invalid primary-key ordering metadata.")
        }

        return PostgresChangeTableMetadata(
            columns: columns,
            columnTypeOIDs: columnTypeOIDs,
            primaryKey: primaryKeyEntries.map(\.column))
    }

    // MARK: - Identifier quoting

    /// Double-quote a PostgreSQL identifier. Rejects empty names and NUL bytes.
    public static func quoteIdentifier(_ identifier: String) throws -> String {
        guard !identifier.isEmpty, !identifier.contains("\0") else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL identifiers must be non-empty strings without null bytes.")
        }
        return "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Snapshot validation

    private static func validatedEntries(
        _ entries: [PostgresFieldEntry], label: String
    ) throws -> [PostgresFieldEntry] {
        var seen: Set<String> = []
        for (column, _) in entries {
            guard !column.isEmpty, !column.contains("\0") else {
                throw PostgresChangePlanError(reason: "\(label) contains an invalid field name.")
            }
            if dangerousFieldNames.contains(column) {
                throw PostgresChangePlanError(
                    reason: "\(label) contains the dangerous key \(column).")
            }
            guard seen.insert(column).inserted else {
                throw PostgresChangePlanError(reason: "\(label) contains a duplicate field name.")
            }
        }
        return entries
    }

    private struct Target {
        let qualifiedTable: String
        let primaryKey: [PostgresFieldEntry]
        let original: [PostgresFieldEntry]
    }

    private static func target(
        schema: String,
        table: String,
        primaryKey: [PostgresFieldEntry],
        original: [PostgresFieldEntry]
    ) throws -> Target {
        let qualifiedTable = try "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
        let key = try validatedEntries(primaryKey, label: "PostgreSQL primary key")
        let originalEntries = try validatedEntries(original, label: "PostgreSQL original patch")

        guard !key.isEmpty else {
            throw PostgresChangePlanError(
                reason: "A PostgreSQL single-row change requires at least one primary-key column.")
        }
        guard !originalEntries.isEmpty else {
            throw PostgresChangePlanError(
                reason: "A PostgreSQL single-row change requires original values for concurrency checks.")
        }

        let keyValues = Dictionary(key.map { ($0.column, $0.value) }) { first, _ in first }
        for (column, value) in key where value == .null {
            throw PostgresChangePlanError(
                reason: "PostgreSQL primary-key column \(column) cannot be null.")
        }
        for (column, value) in originalEntries {
            if let keyValue = keyValues[column], keyValue != value {
                throw PostgresChangePlanError(
                    reason: "PostgreSQL original value for primary-key column \(column) is inconsistent.")
            }
        }

        return Target(qualifiedTable: qualifiedTable, primaryKey: key, original: originalEntries)
    }

    private static func appendWhere(
        values: inout [DisplayValue],
        columnTypeOIDs: [String: Int],
        primaryKey: [PostgresFieldEntry],
        original: [PostgresFieldEntry]
    ) throws -> String {
        var conditions: [String] = []
        let keyColumns = Set(primaryKey.map(\.column))

        for (column, value) in primaryKey {
            values.append(value)
            try conditions.append(equality(
                column: column, columnTypeOIDs: columnTypeOIDs, placeholder: values.count))
        }
        for (column, value) in original where !keyColumns.contains(column) {
            values.append(value)
            try conditions.append(equality(
                column: column, columnTypeOIDs: columnTypeOIDs, placeholder: values.count))
        }
        return conditions.joined(separator: "\n  AND ")
    }

    /// The NULL-safe optimistic-lock predicate for one column. Byte-compared
    /// columns match their canonical UTF-8 text on both sides (`convert_to`
    /// maps NULL to NULL, so `IS NOT DISTINCT FROM` keeps its NULL
    /// semantics); everything else compares natively.
    private static func equality(
        column: String, columnTypeOIDs: [String: Int], placeholder: Int
    ) throws -> String {
        let quoted = try quoteIdentifier(column)
        if let oid = columnTypeOIDs[column], byteComparedTypeOIDs.contains(oid) {
            return "convert_to(\(quoted)::text, 'UTF8')"
                + " IS NOT DISTINCT FROM convert_to($\(placeholder)::text, 'UTF8')"
        }
        return "\(quoted) IS NOT DISTINCT FROM $\(placeholder)"
    }

    // MARK: - Plans

    /// Plans one optimistic row update. `original` and `current` must contain
    /// the same columns; only values that actually changed are assigned.
    /// `columnTypeOIDs` (from the change metadata) selects byte-level
    /// matching for the text family and `numeric`.
    public static func planUpdate(
        schema: String,
        table: String,
        columnTypeOIDs: [String: Int],
        primaryKey: [PostgresFieldEntry],
        original: [PostgresFieldEntry],
        current: [PostgresFieldEntry]
    ) throws -> PostgresParameterizedPlan {
        let target = try target(
            schema: schema, table: table, primaryKey: primaryKey, original: original)
        let currentEntries = try validatedEntries(current, label: "PostgreSQL current patch")
        let originalValues = Dictionary(target.original.map { ($0.column, $0.value) }) { first, _ in first }

        guard currentEntries.count == target.original.count,
              currentEntries.allSatisfy({ originalValues[$0.column] != nil })
        else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL original and current patches must contain the same columns.")
        }

        let keyColumns = Set(target.primaryKey.map(\.column))
        let changed = currentEntries.filter { originalValues[$0.column]! != $0.value }
        guard !changed.isEmpty else {
            throw PostgresChangePlanError(
                reason: "A PostgreSQL update patch must contain at least one changed value.")
        }
        if let changedKey = changed.first(where: { keyColumns.contains($0.column) }) {
            throw PostgresChangePlanError(
                reason: "PostgreSQL primary-key column \(changedKey.column) cannot be edited.")
        }

        var values: [DisplayValue] = []
        var assignments: [String] = []
        for (column, value) in changed {
            values.append(value)
            try assignments.append("\(quoteIdentifier(column)) = $\(values.count)")
        }
        var whereValues = values
        let whereClause = try appendWhere(
            values: &whereValues, columnTypeOIDs: columnTypeOIDs,
            primaryKey: target.primaryKey, original: target.original)

        return PostgresParameterizedPlan(
            text: [
                "UPDATE \(target.qualifiedTable)",
                "SET \(assignments.joined(separator: ",\n    "))",
                "WHERE \(whereClause)",
                "RETURNING *;",
            ].joined(separator: "\n"),
            values: whereValues)
    }

    /// Plans one optimistic row delete without executing it.
    /// `columnTypeOIDs` selects byte-level matching, as in `planUpdate`.
    public static func planDelete(
        schema: String,
        table: String,
        columnTypeOIDs: [String: Int],
        primaryKey: [PostgresFieldEntry],
        original: [PostgresFieldEntry]
    ) throws -> PostgresParameterizedPlan {
        let target = try target(
            schema: schema, table: table, primaryKey: primaryKey, original: original)
        var values: [DisplayValue] = []
        let whereClause = try appendWhere(
            values: &values, columnTypeOIDs: columnTypeOIDs,
            primaryKey: target.primaryKey, original: target.original)

        return PostgresParameterizedPlan(
            text: [
                "DELETE FROM \(target.qualifiedTable)",
                "WHERE \(whereClause)",
                "RETURNING *;",
            ].joined(separator: "\n"),
            values: values)
    }

    /// Plans one row insert. There is no optimistic lock (the row does not
    /// exist yet); the same field-name validation as updates applies. Values
    /// bind in entry order (`$1…`); omitted columns take their server
    /// default, and an empty entry list becomes `DEFAULT VALUES`.
    /// `RETURNING *` yields the inserted row — zero rows means a trigger or
    /// RLS policy intercepted the write, reported with the same
    /// conflict wording as updates.
    public static func planInsert(
        schema: String,
        table: String,
        entries: [PostgresFieldEntry]
    ) throws -> PostgresParameterizedPlan {
        let qualifiedTable = try "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
        let validated = try validatedEntries(entries, label: "PostgreSQL insert values")

        guard !validated.isEmpty else {
            return PostgresParameterizedPlan(
                text: "INSERT INTO \(qualifiedTable) DEFAULT VALUES\nRETURNING *;",
                values: [])
        }
        var values: [DisplayValue] = []
        var columns: [String] = []
        var placeholders: [String] = []
        for (column, value) in validated {
            values.append(value)
            try columns.append(quoteIdentifier(column))
            placeholders.append("$\(values.count)")
        }
        return PostgresParameterizedPlan(
            text: [
                "INSERT INTO \(qualifiedTable) (\(columns.joined(separator: ", ")))",
                "VALUES (\(placeholders.joined(separator: ", ")))",
                "RETURNING *;",
            ].joined(separator: "\n"),
            values: values)
    }
}
