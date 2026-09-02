import Foundation
import dbbbbCore

/// One row of a tabular result, with preformatted cell strings for `Table`.
struct RowModel: Identifiable {
    let id: Int
    let values: [DisplayValue]

    var cells: [String] { values.map(DisplayFormatting.cellText) }
}

/// One node in the monospaced document tree (MongoDB results).
struct DocNode: Identifiable {
    let id = UUID()
    let label: String
    let valueText: String?
    let isNull: Bool
    let children: [DocNode]?
    /// Index of the document this node belongs to; set on root nodes only.
    let documentIndex: Int?

    static func make(label: String, value: DisplayValue, documentIndex: Int? = nil) -> DocNode {
        switch value {
        case .object(let pairs):
            DocNode(label: label, valueText: nil, isNull: false,
                    children: pairs.map { make(label: $0.key, value: $0.value) },
                    documentIndex: documentIndex)
        case .array(let items):
            DocNode(label: label, valueText: nil, isNull: false,
                    children: items.enumerated().map { make(label: "[\($0.offset)]", value: $0.element) },
                    documentIndex: documentIndex)
        case .null:
            DocNode(label: label, valueText: "null", isNull: true, children: nil,
                    documentIndex: documentIndex)
        default:
            DocNode(label: label, valueText: DisplayFormatting.cellText(value), isNull: false,
                    children: nil, documentIndex: documentIndex)
        }
    }
}
