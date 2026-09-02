import Foundation
import dbbbbCore

/// Export failures. Messages are pre-redacted (no file paths ever appear here)
/// and safe to show verbatim.
public enum ResultExportError: dbbbbError, Equatable {
    /// A value has no portable representation (binary, non-finite number).
    case unsupportedValue
    /// A row/document does not match the declared shape.
    case invalidShape

    public var userMessage: String {
        switch self {
        case .unsupportedValue:
            "The result contains a value that cannot be exported."
        case .invalidShape:
            "The result has an unexpected shape and cannot be exported."
        }
    }
}

/// Stable, compact JSON for already-normalized display values, ported from the
/// Electron `canonicalJson`: object keys are sorted, separators are compact,
/// and precision-sensitive values (which cross as strings) stay strings.
public enum CanonicalJSON {
    private static let maxDepth = 100

    public static func serialize(_ value: DisplayValue) throws -> String {
        try serialize(value, depth: 0)
    }

    private static func serialize(_ value: DisplayValue, depth: Int) throws -> String {
        guard depth <= maxDepth else { throw ResultExportError.unsupportedValue }
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            guard let text = jsonNumber(number) else { throw ResultExportError.unsupportedValue }
            return text
        case .string(let string):
            return quote(string)
        case .binary:
            // WireValue has no binary case; the Electron export fails closed on
            // unsupported shapes, and so do we.
            throw ResultExportError.unsupportedValue
        case .array(let items):
            return try "[" + items.map { try serialize($0, depth: depth + 1) }.joined(separator: ",") + "]"
        case .object(let pairs):
            let properties = try pairs
                .sorted { $0.key < $1.key }
                .map { try "\(quote($0.key)):\(serialize($0.value, depth: depth + 1))" }
            return "{" + properties.joined(separator: ",") + "}"
        }
    }

    /// JS `JSON.stringify(number)`: finite only; integral values within the
    /// safe-integer range keep their exact integer text.
    static func jsonNumber(_ number: Double) -> String? {
        guard number.isFinite else { return nil }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        return String(number)
    }

    /// JS `JSON.stringify(string)` escaping: quotes, backslashes, the named
    /// control escapes, and `\u00XX` for the remaining C0 controls.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// One finished export payload.
public struct ExportedResult: Sendable, Equatable {
    public let data: Data
    /// `csv` for row results, `jsonl` for document results.
    public let fileExtension: String
    /// Data rows or documents written. A CSV header is not counted.
    public let rows: Int
    public init(data: Data, fileExtension: String, rows: Int) {
        self.data = data; self.fileExtension = fileExtension; self.rows = rows
    }
}

/// Serializes the *displayed* query result — already capped by the execution
/// bounds — exactly as the Electron `result-export.ts` does: row results
/// become CSV (header + CRLF records), document results become canonical
/// JSONL (one compact JSON document per LF-terminated line).
public enum ResultExporter {
    public static func exportData(for result: QueryResult) throws -> ExportedResult {
        switch result {
        case .rows(let columns, let rows, _):
            return try csvExport(columns: columns, rows: rows)
        case .documents(let documents, _):
            return try jsonLinesExport(documents: documents)
        }
    }

    private static func csvExport(columns: [ColumnMeta], rows: [[DisplayValue]]) throws -> ExportedResult {
        var text = CSVSerializer.record(columns.map(\.name))
        for row in rows {
            guard row.count == columns.count else { throw ResultExportError.invalidShape }
            text += CSVSerializer.record(try row.map(csvCell))
        }
        return ExportedResult(data: Data(text.utf8), fileExtension: "csv", rows: rows.count)
    }

    /// One CSV cell, mirroring the Electron `csvCell`: scalars cross as their
    /// plain text, nested values as canonical JSON, and anything without a
    /// portable representation fails closed.
    private static func csvCell(_ value: DisplayValue) throws -> String {
        switch value {
        case .null:
            return ""
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            guard let text = CanonicalJSON.jsonNumber(number) else {
                throw ResultExportError.unsupportedValue
            }
            return text
        case .string(let string):
            return string
        case .array, .object:
            return try CanonicalJSON.serialize(value)
        case .binary:
            throw ResultExportError.unsupportedValue
        }
    }

    private static func jsonLinesExport(documents: [DisplayValue]) throws -> ExportedResult {
        var text = ""
        for document in documents {
            guard case .object = document else { throw ResultExportError.invalidShape }
            text += try CanonicalJSON.serialize(document) + "\n"
        }
        return ExportedResult(data: Data(text.utf8), fileExtension: "jsonl", rows: documents.count)
    }
}
