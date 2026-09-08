import Foundation
import Testing
import dbbbbCore
@testable import dbbbbApp

/// Popup value-editor mechanics (ROADMAP M3 值编辑器): mode detection,
/// initial content, validation hints, and parse fidelity. Type fidelity is
/// the point: text/JSON commit as verbatim strings, binary as bytes.
struct ValueEditingTests {
    // MARK: Mode detection

    @Test func jsonObjectStringOpensAsJSON() {
        #expect(ValueEditing.kind(for: .string("{\"a\":1}")) == .json)
        #expect(ValueEditing.kind(for: .string("[1, 2]")) == .json)
    }

    @Test func plainOrBrokenStringsOpenAsText() {
        #expect(ValueEditing.kind(for: .string("hello")) == .text)
        #expect(ValueEditing.kind(for: .string("{not json")) == .text)
        // A scalar-looking string is not reinterpreted as JSON.
        #expect(ValueEditing.kind(for: .string("123")) == .text)
    }

    @Test func binaryOpensAsBinary() {
        #expect(ValueEditing.kind(for: .binary(Data([0xDE, 0xAD]))) == .binary)
    }

    @Test func otherKindsHaveNoEditor() {
        #expect(ValueEditing.kind(for: .null) == nil)
        #expect(ValueEditing.kind(for: .number(1)) == nil)
        #expect(ValueEditing.kind(for: .bool(true)) == nil)
        #expect(ValueEditing.kind(for: .array([.null])) == nil)
    }

    // MARK: Initial text

    @Test func initialTextIsVerbatimForTextAndPrettyForJSON() {
        #expect(ValueEditing.initialText(for: .string("a\nb"), kind: .text) == "a\nb")
        let pretty = ValueEditing.initialText(for: .string("{\"a\":1}"), kind: .json)
        #expect(pretty.contains("\n"))
        #expect(pretty.contains("\"a\" : 1"))
    }

    @Test func initialTextIsSpacedUppercaseHexForBinary() {
        #expect(ValueEditing.initialText(for: .binary(Data([0x00, 0x0F, 0xFF])), kind: .binary)
            == "00 0F FF")
    }

    // MARK: Parse fidelity

    @Test func textParsesVerbatim() throws {
        #expect(try ValueEditing.parse("  padded text \n", kind: .text) == .string("  padded text \n"))
    }

    /// JSON commits as the exact edited text — validation only, never a
    /// rewrite or a type conversion.
    @Test func jsonParsesVerbatimString() throws {
        let compact = "{\"a\":  1}"
        #expect(try ValueEditing.parse(compact, kind: .json) == .string(compact))
    }

    @Test func invalidJSONFailsClosed() {
        #expect(throws: (any Error).self) { try ValueEditing.parse("{oops", kind: .json) }
    }

    @Test func binaryRoundTripsThroughHex() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let parsed = try ValueEditing.parse("DE AD be ef", kind: .binary)
        #expect(parsed == .binary(data))
    }

    @Test func emptyHexIsEmptyData() throws {
        #expect(try ValueEditing.parse("", kind: .binary) == .binary(Data()))
        #expect(try ValueEditing.parse(" \n", kind: .binary) == .binary(Data()))
    }

    @Test func malformedHexFailsClosed() {
        // Odd digit count.
        #expect(throws: (any Error).self) { try ValueEditing.parse("ABC", kind: .binary) }
        // Non-hex characters.
        #expect(throws: (any Error).self) { try ValueEditing.parse("GG", kind: .binary) }
        // Non-ASCII is rejected even when it looks like a digit.
        #expect(throws: (any Error).self) { try ValueEditing.parse("１２", kind: .binary) }
    }

    // MARK: Validation hints

    @Test func jsonValidationAcceptsDocumentsAndFragments() {
        #expect(ValueEditing.jsonValidationError("{\"a\":1}") == nil)
        #expect(ValueEditing.jsonValidationError("[1]") == nil)
        // Bare scalars/strings are valid JSON fragments (a JSON column may
        // legitimately hold one).
        #expect(ValueEditing.jsonValidationError("5") == nil)
        #expect(ValueEditing.jsonValidationError("\"x\"") == nil)
    }

    @Test func jsonValidationFlagsBrokenInput() {
        #expect(ValueEditing.jsonValidationError("{oops") != nil)
        #expect(ValueEditing.jsonValidationError("not json") != nil)
    }

    @Test func hexValidationMirrorsDecoding() {
        #expect(ValueEditing.hexValidationError("DE AD") == nil)
        #expect(ValueEditing.hexValidationError("ABC") != nil)
    }

    // MARK: Detail-pane editability

    @Test func longValueKindsAreEditableWhenComplete() {
        let text = RowDetailItem.make(index: 0, column: "c", value: .string("hello"))
        #expect(text.isValueEditable)
        let json = RowDetailItem.make(index: 0, column: "c", value: .string("{\"a\":1}"))
        #expect(json.isValueEditable)
        let binary = RowDetailItem.make(index: 0, column: "c", value: .binary(Data([0x01])))
        #expect(binary.isValueEditable)
    }

    @Test func scalarKindsAreNotEditable() {
        #expect(!RowDetailItem.make(index: 0, column: "c", value: .null).isValueEditable)
        #expect(!RowDetailItem.make(index: 0, column: "c", value: .number(1)).isValueEditable)
        #expect(!RowDetailItem.make(index: 0, column: "c", value: .bool(true)).isValueEditable)
    }

    /// A truncated value is never editable: the app holds only its prefix,
    /// so a commit would overwrite the unseen tail.
    @Test func truncatedValuesAreNotEditable() {
        let truncatedText = RowDetailItem.make(
            index: 0, column: "c",
            value: .string("prefix …[dbbbb truncated 42 bytes]"))
        #expect(!truncatedText.isValueEditable)
        var data = Data([0xDE, 0xAD])
        data.append(contentsOf: "…[dbbbb truncated 64 bytes]".utf8)
        let truncatedBinary = RowDetailItem.make(index: 0, column: "c", value: .binary(data))
        #expect(!truncatedBinary.isValueEditable)
    }
}
