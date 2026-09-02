import Foundation
import dbbbbCore
import NIOCore
import PostgresNIO

/// One bind parameter sent in *text* format with its catalog type OID — the
/// equivalent of the Electron adapter's node-postgres text binds. The server
/// parses the text with the declared type's input function, so the canonical
/// display text of a value round-trips losslessly and values never touch the
/// SQL text.
struct PostgresTextParameter: PostgresThrowingDynamicTypeEncodable, Sendable {
    let psqlType: PostgresDataType
    let text: String

    var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer,
        context: PostgresEncodingContext<JSONEncoder>
    ) throws {
        byteBuffer.writeString(text)
    }
}

/// Adapter-side glue between `DataChange` dictionaries and the pure planner:
/// catalog-ordered record mapping, optimistic patch assembly, and the
/// DisplayValue → bind-text conversion. Pure and offline; the adapter owns I/O.
enum PostgresChangeMapper {
    /// Folds a UI record into catalog-ordered entries. Unknown fields are
    /// rejected; catalog columns missing from the record are skipped
    /// (column-level privileges may hide them), mirroring the Electron
    /// adapter's `normalizedChangeRecord`.
    static func orderedEntries(
        _ record: [String: DisplayValue],
        metadata: PostgresChangeTableMetadata,
        label: String
    ) throws -> [PostgresFieldEntry] {
        let allowed = Set(metadata.columns)
        for key in record.keys where !allowed.contains(key) {
            throw PostgresChangePlanError(reason: "\(label) contains an unknown table field.")
        }
        return metadata.columns.compactMap { column in
            record[column].map { (column, $0) }
        }
    }

    /// The optimistic patch: original entries with the reviewed changes
    /// applied. Changed fields outside the original record make the payload
    /// inconsistent and are rejected — the planner's same-columns rule.
    static func currentEntries(
        original: [PostgresFieldEntry],
        changed: [String: DisplayValue]
    ) throws -> [PostgresFieldEntry] {
        var remaining = changed
        let current = original.map { entry in
            if let value = remaining.removeValue(forKey: entry.column) {
                return (entry.column, value)
            }
            return entry
        }
        guard remaining.isEmpty else {
            throw PostgresChangePlanError(
                reason: "PostgreSQL original and current patches must contain the same columns.")
        }
        return current
    }

    /// Primary-key entries in key order; values always come from the original
    /// record (primary keys are not editable).
    static func primaryKeyEntries(
        metadata: PostgresChangeTableMetadata,
        original: [PostgresFieldEntry]
    ) throws -> [PostgresFieldEntry] {
        let originalValues = Dictionary(original.map { ($0.column, $0.value) }) { first, _ in first }
        return try metadata.primaryKey.map { column in
            guard let value = originalValues[column] else {
                throw PostgresChangePlanError(
                    reason: "PostgreSQL change payload is missing a primary-key value.")
            }
            return (column, value)
        }
    }

    /// The catalog column behind every value in a finished plan, in bind
    /// order: changed assignments (in current order), then the primary key,
    /// then the remaining original values. This is the planner's
    /// deterministic value ordering, pinned by `PostgresChangePlannerTests`.
    static func bindColumns(
        primaryKey: [PostgresFieldEntry],
        original: [PostgresFieldEntry],
        current: [PostgresFieldEntry]?
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

    /// Canonical server-input text for one bind value; nil means SQL NULL.
    /// Display strings are the server's own renderings, so they parse back
    /// exactly; numbers keep integers integral (`int4` rejects `5.0`);
    /// binary crosses as `bytea` hex; arrays become array literals.
    static func bindText(for value: DisplayValue, label: String) throws -> String? {
        switch value {
        case .null:
            return nil
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            guard number.isFinite else {
                throw PostgresChangePlanError(reason: "\(label) is not a finite number.")
            }
            if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return String(Int64(number))
            }
            return String(number)
        case .string(let text):
            return text
        case .binary(let data):
            return "\\x" + data.map { String(format: "%02x", $0) }.joined()
        case .array(let values):
            return try arrayLiteral(values, label: label)
        case .object:
            throw PostgresChangePlanError(reason: "\(label) is not a PostgreSQL value.")
        }
    }

    private static func arrayLiteral(_ values: [DisplayValue], label: String) throws -> String {
        let elements = try values.map { try arrayElement($0, label: label) }
        return "{" + elements.joined(separator: ",") + "}"
    }

    private static func arrayElement(_ value: DisplayValue, label: String) throws -> String {
        switch value {
        case .null:
            return "NULL"
        case .array(let values):
            return try arrayLiteral(values, label: label)
        default:
            guard let text = try bindText(for: value, label: label) else { return "NULL" }
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }
}
