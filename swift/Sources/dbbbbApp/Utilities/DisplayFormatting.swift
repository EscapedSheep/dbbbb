import Foundation
import dbbbbCore
import dbbbbKit

/// Pure, UI-independent rendering of `DisplayValue` for cells, trees, and the clipboard.
enum DisplayFormatting {
    /// Short single-line text used in table cells and document-tree leaves.
    static func cellText(_ value: DisplayValue) -> String {
        switch value {
        case .null: "NULL"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): numberText(n)
        case .string(let s): s
        case .binary(let d): "<\(d.count) bytes>"
        case .array, .object: json(value)
        }
    }

    static func numberText(_ n: Double) -> String {
        if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }

    /// Human-readable age for the activity sheet (ROADMAP M2 ⑨): the largest
    /// two units ("45s", "1m 5s", "2h 3m", "1d 2h"); nil (idle/unknown) and
    /// negative durations render "—". Hand-rolled so the output is
    /// locale-independent and unit-testable.
    static func ageText(_ age: Duration?) -> String {
        guard let age, age >= .zero else { return "—" }
        let seconds = age.components.seconds
        if seconds < 60 { return "\(seconds)s" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % 60)s"
    }

    /// Human-readable byte size for the statistics sheet (ROADMAP M2 ⑩):/// 1024-based units with one decimal past KB, nil (unknown) → "—".
    /// Deliberately hand-rolled instead of ByteCountFormatter so the output
    /// is locale-independent and unit-testable.
    static func byteText(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "—" }
        if bytes < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1024
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    /// Compact, key-order-preserving JSON rendering for nested values and copy/paste.
    static func json(_ value: DisplayValue) -> String {
        switch value {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): n.isFinite ? numberText(n) : quote(String(n))
        case .string(let s): quote(s)
        case .binary(let d): "{ \"bytes\": \(d.count) }"
        case .array(let items): "[\(items.map { json($0) }.joined(separator: ", "))]"
        case .object(let pairs): "{ \(pairs.map { "\(quote($0.key)): \(json($0.value))" }.joined(separator: ", ")) }"
        }
    }

    static func tsv(columns: [ColumnMeta], rows: [[DisplayValue]]) -> String {
        ([columns.map(\.name).joined(separator: "\t")]
            + rows.map { $0.map(cellText).joined(separator: "\t") })
            .joined(separator: "\n")
    }

    static func jsonRows(columns: [ColumnMeta], rows: [[DisplayValue]]) -> String {
        let documents = rows.map { row in
            DisplayValue.object(zip(columns, row).map { ($0.0.name, $0.1) })
        }
        return "[\n" + documents.map { "  " + json($0) }.joined(separator: ",\n") + "\n]"
    }

    /// Clipboard exit for "Copy as INSERT". The table name is the best
    /// qualified form recoverable from the (opaque) adapter-issued object id
    /// — `InsertStatementRenderer.tableNameParts` decodes the schema /
    /// database qualification the same way `SelectStatementBuilder` does and
    /// falls back to the bare object name for handles it cannot decode. The
    /// rendering itself (dialect, escaping, fail-closed values) lives in
    /// dbbbbKit and throws `ResultExportError`; callers surface
    /// `dbbbbError.userMessage`.
    static func insertStatements(
        rows: [[DisplayValue]], columns: [ColumnMeta],
        object: DatabaseObject, engine: DatabaseEngine
    ) throws -> String {
        try InsertStatementRenderer.render(
            table: InsertStatementRenderer.tableNameParts(engine: engine, object: object),
            columns: columns, rows: rows)
    }

    // MARK: Row-detail pane rendering (ROADMAP M2 ⑥)

    /// Character budget for a collapsed detail value; longer texts collapse
    /// behind an expand affordance.
    static let detailPreviewLength = 300

    /// Collapsed form of a detail value: the verbatim text when it fits the
    /// budget, otherwise a prefix plus an ellipsis. The full text always stays
    /// available for expansion/copy, so nothing is lost here.
    static func collapsedPreview(of text: String, limit: Int = detailPreviewLength) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Pretty-prints a JSON text, or nil when the text is not parseable JSON
    /// (which then renders verbatim). Only object/array-looking inputs are
    /// attempted, so plain scalars never get reinterpreted.
    static func prettyPrintedJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Byte count of the adapter truncation marker (`…[dbbbb truncated N
    /// bytes]`, see e.g. `MySQLValueMapping.truncatedMarker`) at the end of a
    /// text value; nil when the value was not truncated. Markers are appended
    /// verbatim by the adapters, so detection is a plain suffix parse.
    static func truncatedOmittedBytes(of text: String) -> Int? {
        let suffix = " bytes]"
        guard text.hasSuffix(suffix),
              let open = text.range(of: "…[dbbbb truncated ", options: .backwards)
        else { return nil }
        let digits = text[open.upperBound...].dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    /// Splits an adapter truncation marker off the tail of a binary value (the
    /// adapters append the marker's UTF-8 bytes to truncated blobs), so the
    /// pane can render the real bytes as hex and still flag the omission.
    /// Returns nil for untruncated data.
    static func binaryTruncationSplit(_ data: Data) -> (bytes: Data, omittedBytes: Int)? {
        let prefix = Data("…[dbbbb truncated ".utf8)
        guard let range = data.range(of: prefix, options: .backwards) else { return nil }
        var rest = data[range.upperBound...]
        guard rest.last == UInt8(ascii: "]") else { return nil }
        rest = rest.dropLast()
        let suffix = Data(" bytes".utf8)
        guard rest.count > suffix.count, rest.suffix(suffix.count).elementsEqual(suffix) else { return nil }
        let digits = rest.dropLast(suffix.count)
        guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let omitted = Int(String(decoding: digits, as: UTF8.self))
        else { return nil }
        return (Data(data[..<range.lowerBound]), omitted)
    }

    /// Uppercase, space-separated hex for binary values in the detail pane.
    static func hexText(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}
