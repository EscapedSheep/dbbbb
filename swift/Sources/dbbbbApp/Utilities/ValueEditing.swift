import Foundation
import dbbbbCore

/// The popup value editor's mode (ROADMAP M3 值编辑器): multi-line text,
/// JSON (with pretty/validation affordances), or binary as hex.
enum ValueEditKind: Equatable {
    case text, json, binary
}

/// Pure, UI-independent value-editor mechanics: which mode a value opens in,
/// the editor's initial text, validation hints, and parsing the edited text
/// back into a `DisplayValue`. Type fidelity follows the grid's rules:
/// text/JSON commits cross as strings verbatim (JSON is validated, never
/// converted), binary crosses as bytes decoded from hex.
enum ValueEditing {
    /// Draft-phase validation failures; safe to show verbatim.
    struct Error: dbbbbError, Equatable {
        let userMessage: String
        init(_ message: String) { userMessage = message }
    }

    /// The mode one value opens in; nil for kinds the popup does not edit
    /// (null/number/bool/nested values use the plain field or document
    /// editor). A string opens as JSON only when it actually parses as a
    /// JSON object/array — the same discipline as the detail pane's
    /// pretty-print.
    static func kind(for value: DisplayValue) -> ValueEditKind? {
        switch value {
        case .string(let text):
            return DisplayFormatting.prettyPrintedJSON(text) != nil ? .json : .text
        case .binary:
            return .binary
        default:
            return nil
        }
    }

    /// The editor's initial content: the verbatim string for text, pretty
    /// JSON when it parses, spaced uppercase hex for binary.
    static func initialText(for value: DisplayValue, kind: ValueEditKind) -> String {
        switch (kind, value) {
        case (.text, .string(let text)):
            return text
        case (.json, .string(let text)):
            return DisplayFormatting.prettyPrintedJSON(text) ?? text
        case (.binary, .binary(let data)):
            return DisplayFormatting.hexText(data)
        default:
            return ""
        }
    }

    /// Parses the edited text back into a value. Text and JSON cross as the
    /// verbatim string (JSON is validated first — the commit never rewrites
    /// or converts it); binary decodes the hex.
    static func parse(_ text: String, kind: ValueEditKind) throws -> DisplayValue {
        switch kind {
        case .text:
            return .string(text)
        case .json:
            if let problem = jsonValidationError(text) {
                throw Error("The JSON is invalid: \(problem)")
            }
            return .string(text)
        case .binary:
            return .binary(try hexData(text))
        }
    }

    /// Human-readable reason the text is not valid JSON; nil when valid.
    /// Fragments (a bare scalar/string) count as valid JSON — a JSON column
    /// may legitimately hold one — but pretty-printing stays object/array-only.
    static func jsonValidationError(_ text: String) -> String? {
        guard let data = text.data(using: .utf8) else {
            return "the text is not valid UTF-8"
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            return nil
        } catch let error as NSError {
            return error.localizedDescription
        }
    }

    /// Validation hint for hex input: nil when the text decodes cleanly,
    /// otherwise the reason. Empty input is valid (zero bytes).
    static func hexValidationError(_ text: String) -> String? {
        do {
            _ = try hexData(text)
            return nil
        } catch let error as dbbbbError {
            return error.userMessage
        } catch {
            return "invalid hex"
        }
    }

    /// Decodes hex text into bytes: case-insensitive pairs, whitespace
    /// (spaces/newlines/tabs) ignored between pairs — the exact inverse of
    /// `DisplayFormatting.hexText`. Odd digit counts and non-hex characters
    /// fail closed.
    static func hexData(_ text: String) throws -> Data {
        var digits: [UInt8] = []
        digits.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            guard scalar.isASCII else {
                throw Error("Hex input may only contain 0-9, A-F, and whitespace.")
            }
            digits.append(UInt8(scalar.value))
        }
        guard digits.count % 2 == 0 else {
            throw Error("Hex input needs an even number of digits (\(digits.count) given).")
        }
        var data = Data()
        data.reserveCapacity(digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else {
                throw Error("Hex input may only contain 0-9, A-F, and whitespace.")
            }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
