import Foundation
import dbbbbCore

/// One row of a tabular result, with preformatted cell strings for `Table`.
struct RowModel: Identifiable {
    let id: Int
    let values: [DisplayValue]

    var cells: [String] { values.map(DisplayFormatting.cellText) }
}

/// One node in the monospaced document tree (MongoDB results). `id` is
/// derived from the document path, so rebuilding the tree for a new result
/// keeps identities stable and SwiftUI retains expansion state.
struct DocNode: Identifiable {
    let id: String
    let label: String
    let valueText: String?
    let isNull: Bool
    let children: [DocNode]?
    /// Index of the document this node belongs to; set on root nodes only.
    let documentIndex: Int?

    static func make(label: String, value: DisplayValue, documentIndex: Int? = nil) -> DocNode {
        make(id: label, label: label, value: value, documentIndex: documentIndex)
    }

    private static func make(id: String, label: String, value: DisplayValue, documentIndex: Int? = nil) -> DocNode {
        switch value {
        case .object(let pairs):
            DocNode(id: id, label: label, valueText: nil, isNull: false,
                    children: pairs.enumerated().map {
                        make(id: "\(id)/\($0.offset)", label: $0.element.key, value: $0.element.value)
                    },
                    documentIndex: documentIndex)
        case .array(let items):
            DocNode(id: id, label: label, valueText: nil, isNull: false,
                    children: items.enumerated().map {
                        make(id: "\(id)/\($0.offset)", label: "[\($0.offset)]", value: $0.element)
                    },
                    documentIndex: documentIndex)
        case .null:
            DocNode(id: id, label: label, valueText: "null", isNull: true, children: nil,
                    documentIndex: documentIndex)
        default:
            DocNode(id: id, label: label, valueText: DisplayFormatting.cellText(value), isNull: false,
                    children: nil, documentIndex: documentIndex)
        }
    }
}

/// One column/value pair rendered in the row-detail pane (ROADMAP M2 ⑥).
/// Assembly is pure — all rendering decisions are testable without a view.
struct RowDetailItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case null, text, json, binary, number, bool
    }

    /// Column index within the result row.
    let id: Int
    let column: String
    let kind: Kind
    /// Full text form: the copy payload and the expanded rendering. JSON is
    /// pretty-printed (only when it parses), binary is hex.
    let fullText: String
    /// Collapsed rendering; equals `fullText` when nothing is hidden.
    let collapsedText: String
    /// Set when the adapter truncated this value (`…[dbbbb truncated N
    /// bytes]`): the pane flags the value as truncated on top of carrying
    /// the marker verbatim in the text.
    let truncatedOmittedBytes: Int?

    var isCollapsible: Bool { fullText != collapsedText }

    /// Whether the value editor may open on this item (ROADMAP M3 值编辑器):
    /// only complete values — an adapter-truncated value is never edited
    /// because the app does not hold its full bytes, so a commit would
    /// silently overwrite the untruncated tail with the visible prefix.
    /// null/number/bool cells use the plain record-editor fields instead.
    var isValueEditable: Bool {
        guard truncatedOmittedBytes == nil else { return false }
        switch kind {
        case .text, .json, .binary: return true
        case .null, .number, .bool: return false
        }
    }

    static func items(columns: [ColumnMeta], values: [DisplayValue]) -> [RowDetailItem] {
        columns.enumerated().map { index, column in
            make(index: index, column: column.name,
                 value: index < values.count ? values[index] : .null)
        }
    }

    static func make(index: Int, column: String, value: DisplayValue) -> RowDetailItem {
        switch value {
        case .null:
            return RowDetailItem(id: index, column: column, kind: .null,
                                 fullText: "NULL", collapsedText: "NULL",
                                 truncatedOmittedBytes: nil)
        case .bool(let b):
            let text = b ? "true" : "false"
            return RowDetailItem(id: index, column: column, kind: .bool,
                                 fullText: text, collapsedText: text,
                                 truncatedOmittedBytes: nil)
        case .number(let n):
            let text = DisplayFormatting.numberText(n)
            return RowDetailItem(id: index, column: column, kind: .number,
                                 fullText: text, collapsedText: text,
                                 truncatedOmittedBytes: nil)
        case .string(let s):
            let omitted = DisplayFormatting.truncatedOmittedBytes(of: s)
            // JSON pretty print only when the text parses; a truncated JSON
            // document fails parsing and renders verbatim (marker included).
            if omitted == nil, let pretty = DisplayFormatting.prettyPrintedJSON(s) {
                return RowDetailItem(id: index, column: column, kind: .json,
                                     fullText: pretty,
                                     collapsedText: DisplayFormatting.collapsedPreview(of: pretty),
                                     truncatedOmittedBytes: nil)
            }
            return RowDetailItem(id: index, column: column, kind: .text,
                                 fullText: s,
                                 collapsedText: DisplayFormatting.collapsedPreview(of: s),
                                 truncatedOmittedBytes: omitted)
        case .binary(let data):
            let split = DisplayFormatting.binaryTruncationSplit(data)
            let hex = DisplayFormatting.hexText(split?.bytes ?? data)
            let full = hex.isEmpty ? "<empty>" : hex
            return RowDetailItem(id: index, column: column, kind: .binary,
                                 fullText: full,
                                 collapsedText: DisplayFormatting.collapsedPreview(of: full),
                                 truncatedOmittedBytes: split?.omittedBytes)
        case .array, .object:
            let compact = DisplayFormatting.json(value)
            let full = DisplayFormatting.prettyPrintedJSON(compact) ?? compact
            return RowDetailItem(id: index, column: column, kind: .json,
                                 fullText: full,
                                 collapsedText: DisplayFormatting.collapsedPreview(of: full),
                                 truncatedOmittedBytes: nil)
        }
    }
}

/// Pure filtering for the object navigator's quick search: case-insensitive
/// `contains` on each object's name. A matching node keeps its whole subtree
/// (context below the hit); a non-matching node survives only on the path to
/// a hit, with just the branches that lead there. An empty/whitespace query
/// returns the tree unchanged.
enum ObjectTreeFilter {
    static func filter(_ nodes: [SessionStore.ObjectNode], query: String) -> [SessionStore.ObjectNode] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nodes }
        return nodes.compactMap { filter($0, needle: needle) }
    }

    private static func filter(_ node: SessionStore.ObjectNode, needle: String) -> SessionStore.ObjectNode? {
        if node.object.name.range(of: needle, options: .caseInsensitive) != nil {
            return node
        }
        guard let children = node.children else { return nil }
        let kept = children.compactMap { filter($0, needle: needle) }
        guard !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }
}
