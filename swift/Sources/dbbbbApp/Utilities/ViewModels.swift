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
