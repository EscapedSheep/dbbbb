import Foundation

/// Errors raised while parsing or validating canonical Extended JSON input.
/// `userMessage` strings are safe to show in the UI.
enum EJSONError: Error, Equatable {
    case invalidJSON
    case expectedDocument(String)
    case expectedPipeline
    case stageNotDocument
    case dangerousKey(String)
    case depthExceeded
    case tooManyValues
    case invalidTagPayload(String)
    case unsupportedTag(String)
    case numberOutOfRange(String)

    var userMessage: String {
        switch self {
        case .invalidJSON:
            "Invalid MongoDB Extended JSON. Check quotes, commas, and BSON tags."
        case .expectedDocument(let label):
            "\(label) must be one JSON object."
        case .expectedPipeline:
            "An aggregation pipeline must be a JSON array of stage objects."
        case .stageNotDocument:
            "Every aggregation stage must be one JSON object."
        case .dangerousKey(let key):
            "The input contains an unsafe object key (\(key))."
        case .depthExceeded:
            "The input exceeds MongoDB's supported nesting depth."
        case .tooManyValues:
            "The input contains too many values."
        case .invalidTagPayload(let detail):
            detail
        case .unsupportedTag(let tag):
            "\(tag) is not supported. dbbbb accepts data-only canonical Extended JSON."
        case .numberOutOfRange(let literal):
            "The number \(literal) does not fit in a BSON int64; use $numberDecimal or $numberDouble."
        }
    }
}

/// Ordered JSON tree. Numbers keep their raw literal so integer width and
/// decimal form survive into the BSON conversion.
enum JSONValue {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])
}

// Tuple associated values do not synthesize Equatable.
extension JSONValue: Equatable {
    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.number(let a), .number(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: false
        }
    }
}

/// Minimal recursive-descent JSON parser that preserves object key order
/// (Foundation's JSONSerialization does not, and order is semantic in BSON).
struct JSONParser {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ text: String) {
        self.bytes = Array(text.utf8)
    }

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard offset == bytes.count else { throw EJSONError.invalidJSON }
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        guard offset < bytes.count else { throw EJSONError.invalidJSON }
        switch bytes[offset] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        default:
            return .number(try parseNumber())
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        offset += 1
        var pairs: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            offset += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw EJSONError.invalidJSON }
            let key = try parseString()
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw EJSONError.invalidJSON }
            offset += 1
            skipWhitespace()
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard peek() == UInt8(ascii: "}") else { throw EJSONError.invalidJSON }
            offset += 1
            return .object(pairs)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        offset += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            offset += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()
            if peek() == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            guard peek() == UInt8(ascii: "]") else { throw EJSONError.invalidJSON }
            offset += 1
            return .array(values)
        }
    }

    private mutating func parseString() throws -> String {
        offset += 1
        var scalars = String.UnicodeScalarView()
        while true {
            guard offset < bytes.count else { throw EJSONError.invalidJSON }
            let byte = bytes[offset]
            switch byte {
            case UInt8(ascii: "\""):
                offset += 1
                return String(scalars)
            case UInt8(ascii: "\\"):
                offset += 1
                guard offset < bytes.count else { throw EJSONError.invalidJSON }
                let escape = bytes[offset]
                offset += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let first = try parseHex4()
                    if (0xD800...0xDBFF).contains(first) {
                        guard offset + 1 < bytes.count,
                              bytes[offset] == UInt8(ascii: "\\"),
                              bytes[offset + 1] == UInt8(ascii: "u")
                        else { throw EJSONError.invalidJSON }
                        offset += 2
                        let second = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(second),
                              let scalar = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
                        else { throw EJSONError.invalidJSON }
                        scalars.append(scalar)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw EJSONError.invalidJSON
                    } else if let scalar = Unicode.Scalar(first) {
                        scalars.append(scalar)
                    } else {
                        throw EJSONError.invalidJSON
                    }
                default:
                    throw EJSONError.invalidJSON
                }
            case 0x00...0x1F:
                throw EJSONError.invalidJSON
            default:
                let length: Int
                if byte < 0x80 { length = 1 }
                else if byte < 0xE0 { length = 2 }
                else if byte < 0xF0 { length = 3 }
                else { length = 4 }
                guard offset + length <= bytes.count else { throw EJSONError.invalidJSON }
                let slice = bytes[offset..<offset + length]
                guard let string = String(bytes: slice, encoding: .utf8) else { throw EJSONError.invalidJSON }
                scalars.append(contentsOf: string.unicodeScalars)
                offset += length
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw EJSONError.invalidJSON }
        var value: UInt32 = 0
        for index in offset..<offset + 4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: throw EJSONError.invalidJSON
            }
            value = value * 16 + digit
        }
        offset += 4
        return value
    }

    private mutating func parseNumber() throws -> String {
        let start = offset
        if peek() == UInt8(ascii: "-") { offset += 1 }
        // int part
        if peek() == UInt8(ascii: "0") {
            offset += 1
        } else if let byte = peek(), byte >= UInt8(ascii: "1"), byte <= UInt8(ascii: "9") {
            while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { offset += 1 }
        } else {
            throw EJSONError.invalidJSON
        }
        // frac part
        if peek() == UInt8(ascii: ".") {
            offset += 1
            guard let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw EJSONError.invalidJSON
            }
            while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { offset += 1 }
        }
        // exp part
        if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
            offset += 1
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { offset += 1 }
            guard let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw EJSONError.invalidJSON
            }
            while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { offset += 1 }
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    private mutating func expectLiteral(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard offset + literalBytes.count <= bytes.count,
              Array(bytes[offset..<offset + literalBytes.count]) == literalBytes
        else { throw EJSONError.invalidJSON }
        offset += literalBytes.count
    }

    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private mutating func skipWhitespace() {
        while offset < bytes.count {
            switch bytes[offset] {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                offset += 1
            default:
                return
            }
        }
    }
}

/// Canonical Extended JSON → BSON conversion, plus a canonical serializer used
/// for byte accounting and round-trip tests.
enum EJSON {
    static let maxDepth = 100
    static let maxValues = 100_000
    static let dangerousKeys: Set<String> = ["__proto__", "constructor", "prototype"]
    /// Recognized-but-rejected EJSON tags: code and legacy types never cross.
    static let unsupportedTags: Set<String> = ["$code", "$codeWithScope", "$symbol", "$dbPointer", "$undefined"]

    /// Parses a find filter: one JSON object.
    static func parseDocument(_ text: String, label: String) throws -> BSONValue {
        let json = try parseJSON(text)
        guard case .object = json else { throw EJSONError.expectedDocument(label) }
        var converter = Converter()
        return try converter.convert(json, depth: 0)
    }

    /// Parses an aggregation pipeline: a JSON array of stage objects.
    static func parsePipeline(_ text: String) throws -> [BSONValue] {
        let json = try parseJSON(text)
        guard case .array(let stages) = json else { throw EJSONError.expectedPipeline }
        var converter = Converter()
        return try stages.map { stage in
            guard case .object = stage else { throw EJSONError.stageNotDocument }
            return try converter.convert(stage, depth: 0)
        }
    }

    static func parseJSON(_ text: String) throws -> JSONValue {
        var parser = JSONParser(text)
        return try parser.parse()
    }

    struct Converter {
        private(set) var valueCount = 0

        mutating func convert(_ json: JSONValue, depth: Int) throws -> BSONValue {
            valueCount += 1
            guard valueCount <= EJSON.maxValues else { throw EJSONError.tooManyValues }
            guard depth <= EJSON.maxDepth else { throw EJSONError.depthExceeded }

            switch json {
            case .null:
                return .null
            case .bool(let bool):
                return .bool(bool)
            case .number(let literal):
                return try convertNumber(literal)
            case .string(let string):
                return .string(string)
            case .array(let values):
                return .array(try values.map { try convert($0, depth: depth + 1) })
            case .object(let pairs):
                if pairs.count == 1, pairs[0].key.hasPrefix("$"), let tagged = try convertTag(pairs[0], depth: depth) {
                    return tagged
                }
                var converted: [(key: String, value: BSONValue)] = []
                converted.reserveCapacity(pairs.count)
                for pair in pairs {
                    guard !EJSON.dangerousKeys.contains(pair.key) else {
                        throw EJSONError.dangerousKey(pair.key)
                    }
                    converted.append((pair.key, try convert(pair.value, depth: depth + 1)))
                }
                return .document(converted)
            }
        }

        private func convertNumber(_ literal: String) throws -> BSONValue {
            if literal.contains(".") || literal.contains("e") || literal.contains("E") {
                guard let double = Double(literal), double.isFinite else {
                    throw EJSONError.numberOutOfRange(literal)
                }
                return .double(double)
            }
            guard let int = Int64(literal) else { throw EJSONError.numberOutOfRange(literal) }
            if let int32 = Int32(exactly: int) { return .int32(int32) }
            return .int64(int)
        }

        /// Handles single-key `$`-tagged objects. Returns nil for unknown tags,
        /// which are ordinary query operator documents (`{"$gt": 5}`).
        private mutating func convertTag(_ pair: (key: String, value: JSONValue), depth: Int) throws -> BSONValue? {
            let payload = pair.value
            switch pair.key {
            case "$oid":
                guard case .string(let hex) = payload, hex.count == 24,
                      let data = Data(hexString: hex), data.count == 12
                else { throw EJSONError.invalidTagPayload("$oid must be a 24-character hex string.") }
                return .objectID(data)
            case "$numberInt":
                guard case .string(let text) = payload, let int = Int32(text)
                else { throw EJSONError.invalidTagPayload("$numberInt must be a 32-bit integer string.") }
                return .int32(int)
            case "$numberLong":
                guard case .string(let text) = payload, let int = Int64(text)
                else { throw EJSONError.invalidTagPayload("$numberLong must be a 64-bit integer string.") }
                return .int64(int)
            case "$numberDouble":
                guard case .string(let text) = payload else {
                    throw EJSONError.invalidTagPayload("$numberDouble must be a string.")
                }
                switch text {
                case "NaN": return .double(.nan)
                case "Infinity": return .double(.infinity)
                case "-Infinity": return .double(-.infinity)
                default:
                    guard let double = Double(text) else {
                        throw EJSONError.invalidTagPayload("$numberDouble must be a valid double string.")
                    }
                    return .double(double)
                }
            case "$numberDecimal":
                guard case .string(let text) = payload, let bits = Decimal128Codec.fromString(text)
                else { throw EJSONError.invalidTagPayload("$numberDecimal must be a valid decimal string.") }
                return .decimal128(low: bits.low, high: bits.high)
            case "$date":
                return .date(milliseconds: try convertDate(payload))
            case "$binary":
                guard case .object(let fields) = payload else {
                    throw EJSONError.invalidTagPayload("$binary must be an object with base64 and subType.")
                }
                var base64: String?
                var subtype: String?
                for field in fields {
                    if field.key == "base64", case .string(let value) = field.value { base64 = value }
                    if field.key == "subType", case .string(let value) = field.value { subtype = value }
                }
                guard let base64, let subtype,
                      let data = Data(base64Encoded: base64),
                      let subtypeByte = UInt8(subtype, radix: 16), subtype.count <= 2
                else { throw EJSONError.invalidTagPayload("$binary requires valid base64 data and a hex subType.") }
                return .binary(subtype: subtypeByte, data: data)
            case "$regularExpression":
                guard case .object(let fields) = payload else {
                    throw EJSONError.invalidTagPayload("$regularExpression must be an object with pattern and options.")
                }
                var pattern: String?
                var options: String?
                for field in fields {
                    if field.key == "pattern", case .string(let value) = field.value { pattern = value }
                    if field.key == "options", case .string(let value) = field.value { options = value }
                }
                guard let pattern, let options else {
                    throw EJSONError.invalidTagPayload("$regularExpression requires pattern and options strings.")
                }
                return .regex(pattern: pattern, options: options)
            case "$timestamp":
                guard case .object(let fields) = payload else {
                    throw EJSONError.invalidTagPayload("$timestamp must be an object with t and i.")
                }
                var seconds: UInt64?
                var increment: UInt64?
                for field in fields {
                    guard case .number(let literal) = field.value, let value = UInt64(literal), value <= UInt32.max else {
                        throw EJSONError.invalidTagPayload("$timestamp t and i must be unsigned 32-bit integers.")
                    }
                    if field.key == "t" { seconds = value }
                    if field.key == "i" { increment = value }
                }
                guard let seconds, let increment else {
                    throw EJSONError.invalidTagPayload("$timestamp requires t and i.")
                }
                return .timestamp(raw: (seconds << 32) | increment)
            case "$minKey":
                return .minKey
            case "$maxKey":
                return .maxKey
            default:
                if EJSON.unsupportedTags.contains(pair.key) {
                    throw EJSONError.unsupportedTag(pair.key)
                }
                return nil
            }
        }

        private mutating func convertDate(_ payload: JSONValue) throws -> Int64 {
            switch payload {
            case .string(let text):
                guard let milliseconds = Self.parseISODate(text) else {
                    throw EJSONError.invalidTagPayload("$date must be an ISO-8601 string or a $numberLong milliseconds object.")
                }
                return milliseconds
            case .object(let fields):
                guard fields.count == 1, fields[0].key == "$numberLong",
                      case .string(let text) = fields[0].value, let milliseconds = Int64(text)
                else {
                    throw EJSONError.invalidTagPayload("$date must be an ISO-8601 string or a $numberLong milliseconds object.")
                }
                return milliseconds
            case .number(let literal):
                guard let milliseconds = Int64(literal) else {
                    throw EJSONError.invalidTagPayload("$date milliseconds must be a 64-bit integer.")
                }
                return milliseconds
            default:
                throw EJSONError.invalidTagPayload("$date must be an ISO-8601 string or a $numberLong milliseconds object.")
            }
        }

        private static func parseISODate(_ text: String) -> Int64? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return Int64((date.timeIntervalSince1970 * 1000).rounded())
            }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { return nil }
            return Int64((date.timeIntervalSince1970 * 1000).rounded())
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data()
        data.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}

/// Canonical Extended JSON serializer. Used to measure document byte size
/// against `ExecuteOptions.maxBytes` and to pin round-trip fidelity in tests.
enum EJSONSerializer {
    static func serialize(_ value: BSONValue) -> String {
        switch value {
        case .double(let double):
            let text: String
            if double.isNaN { text = "NaN" }
            else if double == .infinity { text = "Infinity" }
            else if double == -.infinity { text = "-Infinity" }
            else { text = String(double) }
            return #"{"$numberDouble":"# + escape(text) + "}"
        case .string(let string):
            return escape(string)
        case .document(let pairs):
            return "{" + pairs.map { escape($0.key) + ":" + serialize($0.value) }.joined(separator: ",") + "}"
        case .array(let values):
            return "[" + values.map { serialize($0) }.joined(separator: ",") + "]"
        case .binary(let subtype, let data):
            let subtypeText = String(subtype, radix: 16)
            let padded = subtypeText.count == 1 ? "0" + subtypeText : subtypeText
            return #"{"$binary":{"base64":\#(escape(data.base64EncodedString())),"subType":\#(escape(padded))}}"#
        case .objectID(let data):
            return #"{"$oid":\#(escape(data.map { String(format: "%02x", $0) }.joined()))}"#
        case .bool(let bool):
            return bool ? "true" : "false"
        case .date(let milliseconds):
            return #"{"$date":{"$numberLong":"\#(milliseconds)"}}"#
        case .null:
            return "null"
        case .regex(let pattern, let options):
            return #"{"$regularExpression":{"pattern":\#(escape(pattern)),"options":\#(escape(options))}}"#
        case .javascript(let code):
            return #"{"$code":\#(escape(code))}"#
        case .int32(let int):
            return #"{"$numberInt":"\#(int)"}"#
        case .int64(let int):
            return #"{"$numberLong":"\#(int)"}"#
        case .timestamp(let raw):
            return #"{"$timestamp":{"t":\#(raw >> 32),"i":\#(raw & 0xFFFF_FFFF)}}"#
        case .decimal128(let low, let high):
            return #"{"$numberDecimal":\#(escape(Decimal128Codec.toString(low: low, high: high)))}"#
        case .minKey:
            return #"{"$minKey":1}"#
        case .maxKey:
            return #"{"$maxKey":1}"#
        }
    }

    static func serialize(document pairs: [(key: String, value: BSONValue)]) -> String {
        serialize(.document(pairs))
    }

    private static func escape(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
