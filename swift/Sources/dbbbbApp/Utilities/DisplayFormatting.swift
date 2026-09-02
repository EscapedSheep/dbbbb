import Foundation
import dbbbbCore

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
