import Foundation
import dbbbbCore
import GRDB

/// Adapter-side glue between `DataChange` dictionaries and the pure planner:
/// catalog-ordered record mapping, optimistic patch assembly, and the
/// DisplayValue → `DatabaseValue` bind conversion. Pure and offline; the
/// adapter owns I/O. Mirrors `PostgresChangeMapper`.
enum SQLiteChangeMapper {
    /// Folds a UI record into catalog-ordered entries. Unknown fields are
    /// rejected; catalog columns missing from the record are skipped,
    /// mirroring `PostgresChangeMapper.orderedEntries`.
    static func orderedEntries(
        _ record: [String: DisplayValue],
        metadata: SQLiteChangeTableMetadata,
        label: String
    ) throws -> [SQLiteFieldEntry] {
        let allowed = Set(metadata.columns)
        for key in record.keys where !allowed.contains(key) {
            throw SQLiteChangePlanError(reason: "\(label) contains an unknown table field.")
        }
        return metadata.columns.compactMap { column in
            record[column].map { (column, $0) }
        }
    }

    /// The optimistic patch: original entries with the reviewed changes
    /// applied. Changed fields outside the original record make the payload
    /// inconsistent and are rejected — the planner's same-columns rule.
    static func currentEntries(
        original: [SQLiteFieldEntry],
        changed: [String: DisplayValue]
    ) throws -> [SQLiteFieldEntry] {
        var remaining = changed
        let current = original.map { entry in
            if let value = remaining.removeValue(forKey: entry.column) {
                return (entry.column, value)
            }
            return entry
        }
        guard remaining.isEmpty else {
            throw SQLiteChangePlanError(
                reason: "SQLite original and current patches must contain the same columns.")
        }
        return current
    }

    /// Primary-key entries in key order; values always come from the original
    /// record (primary keys are not editable).
    static func primaryKeyEntries(
        metadata: SQLiteChangeTableMetadata,
        original: [SQLiteFieldEntry]
    ) throws -> [SQLiteFieldEntry] {
        let originalValues = Dictionary(original.map { ($0.column, $0.value) }) { first, _ in first }
        return try metadata.primaryKey.map { column in
            guard let value = originalValues[column] else {
                throw SQLiteChangePlanError(
                    reason: "SQLite change payload is missing a primary-key value.")
            }
            return (column, value)
        }
    }

    /// The catalog column behind every value in a finished plan, in bind
    /// order: changed assignments (in current order), then the primary key,
    /// then the remaining original values. This is the planner's
    /// deterministic value ordering, pinned by `SQLiteChangePlannerTests`.
    static func bindColumns(
        primaryKey: [SQLiteFieldEntry],
        original: [SQLiteFieldEntry],
        current: [SQLiteFieldEntry]?
    ) -> [String] {
        var columns: [String] = []
        if let current {
            let originalValues = Dictionary(original.map { ($0.column, $0.value) }) { first, _ in first }
            columns += current.filter { originalValues[$0.column]! != $0.value }.map(\.column)
        }
        let keyColumns = Set(primaryKey.map(\.column))
        columns += primaryKey.map(\.column)
        columns += original.filter { !keyColumns.contains($0.column) }.map(\.column)
        return columns
    }

    /// One bind value preserving the SQLite storage class. `IS` compares
    /// classes strictly (INTEGER 5 is not REAL 5.0), so numbers bind as
    /// integers whenever the value is integral — except under a REAL-affinity
    /// column, whose stored values are always REAL. Booleans cross as the
    /// 0/1 integers SQLite stores them as.
    static func bind(
        for value: DisplayValue, columnType: String?, label: String
    ) throws -> DatabaseValue {
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return Int64(flag ? 1 : 0).databaseValue
        case .number(let number):
            guard number.isFinite else {
                throw SQLiteChangePlanError(reason: "\(label) is not a finite number.")
            }
            let realAffinity = columnType.map(isRealAffinity) ?? false
            if !realAffinity, number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return Int64(number).databaseValue
            }
            return number.databaseValue
        case .string(let text):
            return text.databaseValue
        case .binary(let data):
            return data.databaseValue
        case .array, .object:
            throw SQLiteChangePlanError(reason: "\(label) is not a SQLite value.")
        }
    }

    /// SQLite's REAL-affinity rule: the declared type contains REAL, FLOA, or
    /// DOUB (and, per the documented affinity order, not INT).
    private static func isRealAffinity(_ declaredType: String) -> Bool {
        !declaredType.contains("INT")
            && (declaredType.contains("REAL")
                || declaredType.contains("FLOA")
                || declaredType.contains("DOUB"))
    }
}
