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
/// Used for nested values inside CSV cells; MongoDB document JSONL export
/// goes through the EJSON layer instead (`EJSONSerializer`).
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
/// bounds. Row results become CSV (header + CRLF records); document results
/// become canonical Extended JSONL (one compact EJSON document per
/// LF-terminated line, keys in their original BSON order) so a MongoDB
/// export re-imports with BSON types intact. On request (`Format.insertStatements`)
/// row results of a known target table instead become a `.sql` file of
/// `INSERT` statements, rendered by `InsertStatementRenderer`.
///
/// CSV formula-injection neutralization: string cells and header names that
/// start with `=`, `+`, `-`, or `@` are prefixed with a single quote `'` —
/// the industry-standard mitigation so spreadsheet apps (Excel, Numbers)
/// display the text instead of executing it as a formula. Trade-off: the
/// quote becomes part of the exported text, so re-importing such a CSV
/// carries the leading `'` into the stored value.
public enum ResultExporter {
    /// Which serialization `exportData(for:format:)` produces.
    public enum Format: Sendable, Equatable {
        /// The automatic mapping: CSV for row results, JSONL for documents.
        case automatic
        /// SQL INSERT statements (`.sql`) for row results. Requires the
        /// qualified target table path; only previews know one. Rendering
        /// reuses `InsertStatementRenderer` (lowest-common-denominator
        /// dialect; see its doc comment). Document results fail closed —
        /// MongoDB exports stay JSONL-only.
        case insertStatements(table: [String])
    }

    public static func exportData(
        for result: QueryResult, format: Format = .automatic
    ) throws -> ExportedResult {
        switch format {
        case .automatic:
            switch result {
            case .rows(let columns, let rows, _):
                return try csvExport(columns: columns, rows: rows)
            case .documents(let documents, _):
                return try jsonLinesExport(documents: documents)
            }
        case .insertStatements(let table):
            guard case .rows(let columns, let rows, _) = result else {
                throw ResultExportError.invalidShape
            }
            let text = try InsertStatementRenderer.render(table: table, columns: columns, rows: rows)
            return ExportedResult(
                data: Data((text + "\n").utf8), fileExtension: "sql", rows: rows.count)
        }
    }

    private static func csvExport(columns: [ColumnMeta], rows: [[DisplayValue]]) throws -> ExportedResult {
        var text = CSVSerializer.record(columns.map { neutralizeFormula($0.name) })
        for row in rows {
            guard row.count == columns.count else { throw ResultExportError.invalidShape }
            text += CSVSerializer.record(try row.map(csvCell))
        }
        return ExportedResult(data: Data(text.utf8), fileExtension: "csv", rows: rows.count)
    }

    /// Formula-injection neutralization: a spreadsheet cell whose text starts
    /// with `=`, `+`, `-`, or `@` would be evaluated as a formula when opened
    /// in Excel/Numbers, so it is prefixed with a single quote. Numbers,
    /// nulls, and empty strings are not affected. See the `ResultExporter`
    /// doc comment for the re-import trade-off.
    static func neutralizeFormula(_ text: String) -> String {
        guard let first = text.first, "=+-@".contains(first) else { return text }
        return "'" + text
    }

    /// One CSV cell, mirroring the Electron `csvCell`: scalars cross as their
    /// plain text, nested values as canonical JSON, and anything without a
    /// portable representation fails closed. String cells pass through
    /// `neutralizeFormula` before serialization.
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
            return neutralizeFormula(string)
        case .array, .object:
            return try CanonicalJSON.serialize(value)
        case .binary:
            throw ResultExportError.unsupportedValue
        }
    }

    /// Canonical EJSON lines via the project's own Extended JSON codec: keys
    /// keep their BSON order, tagged display values pass through verbatim, and
    /// bare numbers are emitted as `$numberDouble`, so the export re-imports
    /// through `MongoImportPlanner` with BSON types intact. Documents with
    /// unsupported tags (`$code`, …) still export but remain fail-closed on
    /// import — see `EJSONSerializer.serialize(displayValue:)`.
    private static func jsonLinesExport(documents: [DisplayValue]) throws -> ExportedResult {
        var text = ""
        for document in documents {
            guard case .object = document else { throw ResultExportError.invalidShape }
            text += try EJSONSerializer.serialize(displayValue: document) + "\n"
        }
        return ExportedResult(data: Data(text.utf8), fileExtension: "jsonl", rows: documents.count)
    }
}

/// Renders the *displayed* rows — already capped by the execution bounds, so
/// truncated values cross verbatim with their `…[dbbbb truncated N bytes]`
/// marker, exactly like the CSV/JSONL exports — as SQL INSERT statements for
/// the clipboard ("Copy as INSERT").
///
/// Dialect trade-off: the export layer has no engine context, so this emits
/// lowest-common-denominator SQL rather than any engine's exact dialect:
/// double-quoted identifiers (standard SQL; accepted by PostgreSQL and
/// SQLite, and by MySQL only under `ANSI_QUOTES`), string literals with
/// single-quote doubling (backslashes pass through unescaped — under MySQL's
/// default sql_mode a backslash may instead be read as an escape
/// introducer), `NULL`, numbers as their exact finite text, booleans as
/// `TRUE`/`FALSE`. Values with no portable SQL literal fail closed, matching
/// the existing export discipline: `.binary` and non-finite numbers throw
/// `ResultExportError.unsupportedValue`; nested arrays/objects cross as a
/// canonical-JSON string literal (key order sorted, as in CSV cells).
public enum InsertStatementRenderer {
    /// One INSERT per row (the maximal common denominator; not every engine
    /// accepts multi-row VALUES in all contexts), each terminated with `;`,
    /// statements separated by newlines. `table` is the qualified identifier
    /// path — every segment is quoted independently.
    public static func render(table: [String], columns: [ColumnMeta], rows: [[DisplayValue]]) throws -> String {
        guard !table.isEmpty else { throw ResultExportError.invalidShape }
        let target = table.map(quoteIdentifier).joined(separator: ".")
        let columnList = "(" + columns.map { quoteIdentifier($0.name) }.joined(separator: ", ") + ")"
        var statements: [String] = []
        for row in rows {
            guard row.count == columns.count else { throw ResultExportError.invalidShape }
            let values = try row.map(literal).joined(separator: ", ")
            statements.append("INSERT INTO \(target) \(columnList) VALUES (\(values));")
        }
        return statements.joined(separator: "\n")
    }

    /// Best-effort qualified table name for "Copy as INSERT", recovered from
    /// the opaque adapter-issued object id with the same decoders
    /// `SelectStatementBuilder` uses. Handles that do not decode (demo
    /// fixtures, ids from other sources) fall back to the bare object name,
    /// which the renderer quotes as a single identifier.
    public static func tableNameParts(engine: DatabaseEngine, object: DatabaseObject) -> [String] {
        switch engine {
        case .postgresql:
            if let ref = PostgresObjectIDCodec.decode(object.id), let name = ref.name {
                return [ref.schema, name]
            }
            return [object.name]
        case .mysql:
            if let ref = MySQLObjectRef(id: object.id), let name = ref.name {
                return [ref.database, name]
            }
            return [object.name]
        case .sqlite:
            // SQLite previews quote the bare name (single-file databases).
            return [object.name]
        case .mongodb, .bullmq:
            // Document/queue results are documents, never rows; the bare name
            // keeps this switch total without implying INSERT support.
            return [object.name]
        }
    }

    /// Standard-SQL identifier quoting: `"` is doubled.
    static func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// One SQL literal per display value; see the enum doc comment for the
    /// dialect and fail-closed rules.
    static func literal(_ value: DisplayValue) throws -> String {
        switch value {
        case .null:
            return "NULL"
        case .bool(let flag):
            return flag ? "TRUE" : "FALSE"
        case .number(let number):
            guard let text = CanonicalJSON.jsonNumber(number) else {
                throw ResultExportError.unsupportedValue
            }
            return text
        case .string(let string):
            return quote(string)
        case .array, .object:
            // Nested values have no portable SQL literal; they cross as a
            // canonical-JSON string (JSON/JSONB columns round-trip this way).
            return try quote(CanonicalJSON.serialize(value))
        case .binary:
            throw ResultExportError.unsupportedValue
        }
    }

    /// Standard-SQL string literal: `'` is doubled; nothing else is escaped.
    static func quote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
