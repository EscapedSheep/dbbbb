import Foundation
import dbbbbCore

/// Ordered JSON parsing and JSON.stringify-compatible serialization for
/// `DisplayValue`. Object key order is preserved both ways so equality
/// comparisons behave exactly like the Electron reference's
/// `JSON.stringify(left) === JSON.stringify(right)`.
enum BullmqJSON {
    /// Parses one JSON text into a `DisplayValue` tree; nil on any malformed
    /// input (the callers treat unparsable fields as absent, like the
    /// reference's `JSON.parse` in a try/catch).
    static func parse(_ text: String) -> DisplayValue? {
        var parser = Parser(Array(text.utf8))
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        guard parser.atEnd else { return nil }
        return value
    }

    /// JSON.stringify-compatible serialization. Object keys keep their
    /// stored order; numbers print the JS way (integral doubles without a
    /// fraction, non-finite as `null`).
    static func stringify(_ value: DisplayValue) -> String {
        var output = ""
        stringify(value, into: &output)
        return output
    }

    /// JS number formatting: `1` not `1.0`, integers up to 2^53 stay exact.
    static func numberString(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func stringify(_ value: DisplayValue, into output: inout String) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let number): output += numberString(number)
        case .string(let string): stringifyString(string, into: &output)
        case .binary(let data): stringifyString(data.base64EncodedString(), into: &output)
        case .array(let elements):
            output += "["
            for (index, element) in elements.enumerated() {
                if index > 0 { output += "," }
                stringify(element, into: &output)
            }
            output += "]"
        case .object(let pairs):
            output += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { output += "," }
                stringifyString(pair.key, into: &output)
                output += ":"
                stringify(pair.value, into: &output)
            }
            output += "}"
        }
    }

    private static func stringifyString(_ string: String, into output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    private struct Parser {
        private let bytes: [UInt8]
        private var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue() -> DisplayValue? {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return parseObject()
            case UInt8(ascii: "["): return parseArray()
            case UInt8(ascii: "\""): return parseString().map(DisplayValue.string)
            case UInt8(ascii: "t"): return parseLiteral("true").map { _ in .bool(true) }
            case UInt8(ascii: "f"): return parseLiteral("false").map { _ in .bool(false) }
            case UInt8(ascii: "n"): return parseLiteral("null").map { _ in .null }
            default: return parseNumber().map(DisplayValue.number)
            }
        }

        private mutating func parseLiteral(_ literal: String) -> Bool? {
            let literalBytes = Array(literal.utf8)
            guard index + literalBytes.count <= bytes.count,
                  Array(bytes[index..<(index + literalBytes.count)]) == literalBytes else { return nil }
            index += literalBytes.count
            return true
        }

        private mutating func parseNumber() -> Double? {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            var sawDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    sawDigit = true; index += 1
                } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
                            || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                    index += 1
                } else {
                    break
                }
            }
            guard sawDigit else { return nil }
            return Double(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private mutating func parseString() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var result = ""
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return result
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): result += "\""
                    case UInt8(ascii: "\\"): result += "\\"
                    case UInt8(ascii: "/"): result += "/"
                    case UInt8(ascii: "b"): result += "\u{08}"
                    case UInt8(ascii: "f"): result += "\u{0C}"
                    case UInt8(ascii: "n"): result += "\n"
                    case UInt8(ascii: "r"): result += "\r"
                    case UInt8(ascii: "t"): result += "\t"
                    case UInt8(ascii: "u"):
                        guard let scalar = parseUnicodeEscape() else { return nil }
                        result.unicodeScalars.append(scalar)
                    default: return nil
                    }
                default:
                    // Accumulate raw UTF-8 runs without re-encoding per byte.
                    var run = [byte]
                    while index < bytes.count,
                          bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") {
                        run.append(bytes[index])
                        index += 1
                    }
                    result += String(decoding: run, as: UTF8.self)
                }
            }
            return nil
        }

        private mutating func parseUnicodeEscape() -> Unicode.Scalar? {
            func readHex4(_ bytes: [UInt8], _ index: inout Int) -> UInt32? {
                guard index + 4 <= bytes.count else { return nil }
                var value: UInt32 = 0
                for byte in bytes[index..<(index + 4)] {
                    guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { return nil }
                    value = value * 16 + UInt32(digit)
                }
                index += 4
                return value
            }
            guard let first = readHex4(bytes, &index) else { return nil }
            if (0xD800...0xDBFF).contains(first) {
                // A high surrogate must be followed by `\uXXXX` low surrogate.
                guard index + 2 <= bytes.count,
                      bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                    return Unicode.Scalar(0xFFFD)
                }
                index += 2
                guard let low = readHex4(bytes, &index), (0xDC00...0xDFFF).contains(low) else {
                    return Unicode.Scalar(0xFFFD)
                }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined)
            }
            return Unicode.Scalar(first)
        }

        private mutating func parseArray() -> DisplayValue? {
            index += 1 // "["
            var elements: [DisplayValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                guard let element = parseValue() else { return nil }
                elements.append(element)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                return nil
            }
        }

        private mutating func parseObject() -> DisplayValue? {
            index += 1 // "{"
            var pairs: [(key: String, value: DisplayValue)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = parseValue() else { return nil }
                pairs.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                return nil
            }
        }
    }
}
