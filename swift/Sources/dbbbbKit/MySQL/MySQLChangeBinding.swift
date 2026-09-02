import Foundation
import dbbbbCore
import MySQLNIO
import NIOCore

/// Adapter-side glue between `DataChange` dictionaries and the pure planner:
/// catalog-ordered record mapping, optimistic patch assembly, and the
/// DisplayValue → `MySQLData` bind conversion. Pure and offline; the adapter
/// owns I/O. Mirrors `PostgresChangeMapper`.
enum MySQLChangeMapper {
    /// Folds a UI record into catalog-ordered entries. Unknown fields are
    /// rejected; catalog columns missing from the record are skipped,
    /// mirroring `PostgresChangeMapper.orderedEntries`.
    static func orderedEntries(
        _ record: [String: DisplayValue],
        metadata: MySQLChangeTableMetadata,
        label: String
    ) throws -> [MySQLFieldEntry] {
        let allowed = Set(metadata.columns)
        for key in record.keys where !allowed.contains(key) {
            throw MySQLChangePlanError(reason: "\(label) contains an unknown table field.")
        }
        return metadata.columns.compactMap { column in
            record[column].map { (column, $0) }
        }
    }

    /// The optimistic patch: original entries with the reviewed changes
    /// applied. Changed fields outside the original record make the payload
    /// inconsistent and are rejected — the planner's same-columns rule.
    static func currentEntries(
        original: [MySQLFieldEntry],
        changed: [String: DisplayValue]
    ) throws -> [MySQLFieldEntry] {
        var remaining = changed
        let current = original.map { entry in
            if let value = remaining.removeValue(forKey: entry.column) {
                return (entry.column, value)
            }
            return entry
        }
        guard remaining.isEmpty else {
            throw MySQLChangePlanError(
                reason: "MySQL original and current patches must contain the same columns.")
        }
        return current
    }

    /// Primary-key entries in key order; values always come from the original
    /// record (primary keys are not editable).
    static func primaryKeyEntries(
        metadata: MySQLChangeTableMetadata,
        original: [MySQLFieldEntry]
    ) throws -> [MySQLFieldEntry] {
        let originalValues = Dictionary(original.map { ($0.column, $0.value) }) { first, _ in first }
        return try metadata.primaryKey.map { column in
            guard let value = originalValues[column] else {
                throw MySQLChangePlanError(
                    reason: "MySQL change payload is missing a primary-key value.")
            }
            return (column, value)
        }
    }

    /// The catalog column behind every value in a finished plan, in bind
    /// order: changed assignments (in current order), then the primary key,
    /// then the remaining original values. This is the planner's
    /// deterministic value ordering, pinned by `MySQLChangePlannerTests`.
    static func bindColumns(
        primaryKey: [MySQLFieldEntry],
        original: [MySQLFieldEntry],
        current: [MySQLFieldEntry]?
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

    /// One bind value for the binary protocol. Display strings are the
    /// server's own renderings, so they coerce back exactly (integer, decimal,
    /// and temporal columns all convert string binds in their own domain);
    /// integral numbers bind as integers so float columns still compare
    /// exactly; binary crosses as blob bytes.
    static func bind(for value: DisplayValue, label: String) throws -> MySQLData {
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return MySQLData(bool: flag)
        case .number(let number):
            guard number.isFinite else {
                throw MySQLChangePlanError(reason: "\(label) is not a finite number.")
            }
            if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return MySQLData(int: Int(Int64(number)))
            }
            return MySQLData(double: number)
        case .string(let text):
            return MySQLData(string: text)
        case .binary(let data):
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            return MySQLData(type: .blob, buffer: buffer)
        case .array, .object:
            throw MySQLChangePlanError(reason: "\(label) is not a MySQL value.")
        }
    }
}
