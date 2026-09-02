import Foundation
import dbbbbCore
import MySQLNIO

/// Converts MySQLNIO text-protocol rows into display-safe values.
///
/// Fidelity rules (mirroring the Electron adapter's driver options):
/// - DATE/DATETIME/TIMESTAMP/TIME stay as the server's raw text — parsing them
///   into `Date` would reinterpret them in the host timezone.
/// - DECIMAL/NEWDECIMAL cross as strings; integers beyond the IEEE-754 safe
///   range cross as strings; non-finite doubles cross as strings.
/// - BLOB-family and binary-charset columns cross as `.binary` data.
enum MySQLValueMapping {
    /// A single value larger than this is truncated and visibly marked.
    static let maxValueBytes = 8 * 1024 * 1024

    /// Largest integer that survives a Double round-trip exactly.
    private static let maxSafeInteger: Int64 = 9_007_199_254_740_991
    private static let maxSafeIntegerUnsigned: UInt64 = 9_007_199_254_740_991

    static func truncatedMarker(omittedBytes: Int) -> String {
        "…[dbbbb truncated \(omittedBytes) bytes]"
    }

    /// A single oversized value must not materialize in full before the row byte
    /// budget applies; truncate it and mark the result so it is visibly incomplete.
    static func boundedString(_ text: String) -> String {
        let bytes = text.utf8.count
        guard bytes > maxValueBytes else { return text }
        let kept = String(decoding: text.utf8.prefix(maxValueBytes), as: UTF8.self)
        return kept + truncatedMarker(omittedBytes: bytes - maxValueBytes)
    }

    static func boundedBinary(_ data: Data) -> Data {
        guard data.count > maxValueBytes else { return data }
        var kept = Data(data.prefix(maxValueBytes))
        kept.append(contentsOf: truncatedMarker(omittedBytes: data.count - maxValueBytes).utf8)
        return kept
    }

    static func displayValue(
        column: MySQLProtocol.ColumnDefinition41,
        buffer: ByteBuffer?
    ) -> DisplayValue {
        guard var buffer else { return .null }
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        let text = String(decoding: bytes, as: UTF8.self)
        let binaryCharset = column.characterSet == .binary

        switch column.columnType {
        case .tiny where column.columnLength == 1:
            // MySQL BOOL is TINYINT(1); only literal 0/1 becomes a bool.
            if text == "1" { return .bool(true) }
            if text == "0" { return .bool(false) }
            return integerValue(text)
        case .tiny, .short, .long, .int24, .year:
            return integerValue(text)
        case .longlong:
            if column.flags.contains(.COLUMN_UNSIGNED), let value = UInt64(text) {
                return value <= maxSafeIntegerUnsigned
                    ? .number(Double(value))
                    : .string(boundedString(text))
            }
            guard let value = Int64(text) else { return .string(boundedString(text)) }
            // No abs(): it traps on Int64.min.
            return value >= -maxSafeInteger && value <= maxSafeInteger
                ? .number(Double(value))
                : .string(boundedString(text))
        case .float, .double:
            guard let value = Double(text), value.isFinite else {
                return .string(boundedString(text))
            }
            return .number(value)
        case .decimal, .newdecimal:
            return .string(boundedString(text))
        case .date, .newdate, .time, .time2, .datetime, .datetime2, .timestamp, .timestamp2:
            return .string(boundedString(text))
        case .bit, .geometry:
            // BIT travels as raw bytes even on the text protocol.
            return .binary(boundedBinary(Data(bytes)))
        case .tinyBlob, .mediumBlob, .longBlob, .blob:
            // TEXT columns share the BLOB wire type but carry a non-binary charset.
            return binaryCharset
                ? .binary(boundedBinary(Data(bytes)))
                : .string(boundedString(text))
        case .json:
            return .string(boundedString(text))
        default:
            // VARCHAR/VAR_STRING/STRING/ENUM/SET and anything unknown: the binary
            // charset marks BINARY/VARBINARY columns.
            return binaryCharset
                ? .binary(boundedBinary(Data(bytes)))
                : .string(boundedString(text))
        }
    }

    private static func integerValue(_ text: String) -> DisplayValue {
        guard let value = Int64(text) else { return .string(boundedString(text)) }
        return .number(Double(value))
    }

    static func isNumeric(_ type: MySQLProtocol.DataType) -> Bool {
        switch type {
        case .decimal, .tiny, .short, .long, .float, .double, .longlong, .int24,
             .year, .newdecimal, .bit:
            true
        default:
            false
        }
    }

    static func columnMeta(_ columns: [MySQLProtocol.ColumnDefinition41]) -> [ColumnMeta] {
        columns.map { column in
            ColumnMeta(
                name: column.name,
                typeName: column.columnType.name
                    .replacingOccurrences(of: "MYSQL_TYPE_", with: "")
                    .lowercased(),
                numeric: isNumeric(column.columnType)
            )
        }
    }

    /// Applies the row-count and byte budgets. MySQLNIO materializes the full
    /// result, so `rawRows.count > maxRows` already proves truncation.
    static func boundedRows(
        rawRows: [MySQLRow],
        maxRows: Int,
        maxBytes: Int
    ) -> (rows: [[DisplayValue]], truncated: Bool) {
        var rows: [[DisplayValue]] = []
        var bytes = 0
        var truncated = rawRows.count > maxRows

        for rawRow in rawRows.prefix(maxRows) {
            let row = zip(rawRow.columnDefinitions, rawRow.values).map { column, value in
                displayValue(column: column, buffer: value)
            }
            let rowBytes = row.reduce(0) { $0 + encodedSize(of: $1) + 2 }
            if bytes + rowBytes > maxBytes {
                truncated = true
                break
            }
            bytes += rowBytes
            rows.append(row)
        }
        return (rows, truncated)
    }

    /// Deterministic size estimate for the byte budget, in the spirit of the
    /// Electron adapter's JSON-encoded row length.
    static func encodedSize(of value: DisplayValue) -> Int {
        switch value {
        case .null: 4
        case .bool: 5
        case .number(let number): String(number).utf8.count
        case .string(let string): string.utf8.count
        case .binary(let data): data.count
        case .array(let values): values.reduce(2) { $0 + encodedSize(of: $1) + 1 }
        case .object(let pairs): pairs.reduce(2) { $0 + $1.key.utf8.count + encodedSize(of: $1.value) + 2 }
        }
    }
}
