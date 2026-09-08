import Foundation
import Testing
import dbbbbCore
@testable import dbbbbApp

/// Row-detail pane formatting (ROADMAP M2 ⑥): pure functions only.
struct RowDetailFormattingTests {
    // MARK: Truncation marker recognition

    @Test func stringTruncationMarkerIsRecognized() {
        #expect(DisplayFormatting.truncatedOmittedBytes(of: "hello …[dbbbb truncated 42 bytes]") == 42)
    }

    @Test func plainStringHasNoTruncationMarker() {
        #expect(DisplayFormatting.truncatedOmittedBytes(of: "plain text") == nil)
        // Marker must sit at the very end.
        #expect(DisplayFormatting.truncatedOmittedBytes(of: "…[dbbbb truncated 12 bytes] tail") == nil)
        // Non-numeric byte count is not a marker.
        #expect(DisplayFormatting.truncatedOmittedBytes(of: "…[dbbbb truncated X bytes]") == nil)
        // Bare lookalike suffix without the marker prefix is not a marker.
        #expect(DisplayFormatting.truncatedOmittedBytes(of: "value ends in 5 bytes]") == nil)
    }

    @Test func binaryTruncationMarkerIsSplitOff() {
        var data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        data.append(contentsOf: "…[dbbbb truncated 128 bytes]".utf8)
        let split = DisplayFormatting.binaryTruncationSplit(data)
        #expect(split?.omittedBytes == 128)
        #expect(split?.bytes == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func binaryWithoutMarkerIsUnsplit() {
        #expect(DisplayFormatting.binaryTruncationSplit(Data([0x00, 0xFF])) == nil)
        // Stray marker prefix without a well-formed tail is not a marker.
        var data = Data([0x01])
        data.append(contentsOf: "…[dbbbb truncated nope]".utf8)
        #expect(DisplayFormatting.binaryTruncationSplit(data) == nil)
    }

    // MARK: Binary hex

    @Test func binaryRendersAsUppercaseHex() {
        let item = RowDetailItem.make(index: 0, column: "blob",
                                      value: .binary(Data([0x00, 0x0F, 0xFF, 0xA5])))
        #expect(item.kind == .binary)
        #expect(item.fullText == "00 0F FF A5")
        #expect(item.truncatedOmittedBytes == nil)
        #expect(!item.isCollapsible)
    }

    @Test func truncatedBinaryRendersHexPlusFlag() {
        var data = Data([0xDE, 0xAD])
        data.append(contentsOf: "…[dbbbb truncated 64 bytes]".utf8)
        let item = RowDetailItem.make(index: 0, column: "blob", value: .binary(data))
        #expect(item.kind == .binary)
        // The marker bytes are not rendered as hex; the omission is flagged.
        #expect(item.fullText == "DE AD")
        #expect(item.truncatedOmittedBytes == 64)
    }

    // MARK: JSON pretty print

    @Test func jsonStringIsPrettyPrinted() {
        let item = RowDetailItem.make(index: 0, column: "doc",
                                      value: .string("{\"a\":1,\"b\":[2,3]}"))
        #expect(item.kind == .json)
        // JSONSerialization pretty output: newline-indented, "key" : value.
        #expect(item.fullText.contains("\n"))
        #expect(item.fullText.contains("\"a\" : 1"))
        #expect(item.fullText.contains("\"b\" : ["))
    }

    @Test func nonJSONStringStaysVerbatim() {
        let item = RowDetailItem.make(index: 0, column: "note",
                                      value: .string("{not valid json"))
        #expect(item.kind == .text)
        #expect(item.fullText == "{not valid json")
        #expect(!item.isCollapsible)
    }

    @Test func scalarLookingStringIsNotReinterpretedAsJSON() {
        let item = RowDetailItem.make(index: 0, column: "n", value: .string("123"))
        #expect(item.kind == .text)
        #expect(item.fullText == "123")
    }

    @Test func truncatedJSONStringStaysVerbatimAndFlagged() {
        // Adapter cut the document mid-way and appended the marker: parsing
        // must fail closed to the verbatim text, marker included.
        let text = "{\"a\":1,\"b\": \"xx…[dbbbb truncated 9 bytes]"
        let item = RowDetailItem.make(index: 0, column: "doc", value: .string(text))
        #expect(item.kind == .text)
        #expect(item.fullText == text)
        #expect(item.truncatedOmittedBytes == 9)
    }

    @Test func nestedValueRendersAsPrettyJSON() {
        let value: DisplayValue = .object([("a", .number(1)), ("b", .array([.null, .bool(true)]))])
        let item = RowDetailItem.make(index: 0, column: "doc", value: value)
        #expect(item.kind == .json)
        #expect(item.fullText.contains("\n"))
        #expect(item.fullText.contains("\"a\" : 1"))
    }

    // MARK: Long text collapse

    @Test func longTextCollapsesWithEllipsis() {
        let long = String(repeating: "x", count: DisplayFormatting.detailPreviewLength + 50)
        let item = RowDetailItem.make(index: 0, column: "body", value: .string(long))
        #expect(item.isCollapsible)
        #expect(item.collapsedText.hasSuffix("…"))
        #expect(item.collapsedText.count == DisplayFormatting.detailPreviewLength + 1)
        // The full text survives untouched for expansion and copy.
        #expect(item.fullText == long)
    }

    @Test func shortTextDoesNotCollapse() {
        let item = RowDetailItem.make(index: 0, column: "name", value: .string("alpha"))
        #expect(!item.isCollapsible)
        #expect(item.collapsedText == "alpha")
        #expect(item.fullText == "alpha")
    }

    @Test func collapsedPreviewBoundary() {
        let exact = String(repeating: "y", count: DisplayFormatting.detailPreviewLength)
        #expect(DisplayFormatting.collapsedPreview(of: exact) == exact)
    }

    // MARK: Row assembly

    @Test func itemsZipColumnsWithValues() {
        let columns = [
            ColumnMeta(name: "id", typeName: "INTEGER", numeric: true),
            ColumnMeta(name: "name", typeName: "TEXT"),
        ]
        let items = RowDetailItem.items(
            columns: columns,
            values: [.number(7), .string("bob")])
        #expect(items.map(\.column) == ["id", "name"])
        #expect(items.map(\.id) == [0, 1])
        #expect(items[0].kind == .number)
        #expect(items[0].fullText == "7")
        #expect(items[1].kind == .text)
    }

    @Test func itemsTolerateShortValueLists() {
        let columns = [ColumnMeta(name: "a", typeName: "T"), ColumnMeta(name: "b", typeName: "T")]
        let items = RowDetailItem.items(columns: columns, values: [.string("only")])
        #expect(items.count == 2)
        #expect(items[1].kind == .null)
    }

    @Test func nullValueRendersUppercase() {
        let item = RowDetailItem.make(index: 0, column: "n", value: .null)
        #expect(item.kind == .null)
        #expect(item.fullText == "NULL")
        #expect(!item.isCollapsible)
    }
}
