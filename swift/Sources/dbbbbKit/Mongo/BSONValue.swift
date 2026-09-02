import Foundation

/// Ordered BSON value tree for the Mongo adapter's own codec.
///
/// MongoKitten's `Document` cannot round-trip every BSON type — `Decimal128`'s
/// bit access is module-internal, so neither parsing `$numberDecimal` nor
/// rendering a stored decimal is possible through its public API. Commands are
/// therefore built here and wrapped with `Document(data:)`, and server replies
/// are read back through `Document.makeData()`.
enum BSONValue: Sendable {
    case double(Double)
    case string(String)
    case document([(key: String, value: BSONValue)])
    case array([BSONValue])
    case binary(subtype: UInt8, data: Data)
    /// Exactly 12 bytes.
    case objectID(Data)
    case bool(Bool)
    /// Milliseconds since the Unix epoch.
    case date(milliseconds: Int64)
    case null
    case regex(pattern: String, options: String)
    case javascript(String)
    case int32(Int32)
    /// Raw little-endian value: increment in the low 32 bits, seconds in the high 32 bits.
    case timestamp(raw: UInt64)
    case int64(Int64)
    case decimal128(low: UInt64, high: UInt64)
    case minKey
    case maxKey
}

// Tuple associated values do not synthesize Equatable.
extension BSONValue: Equatable {
    static func == (lhs: BSONValue, rhs: BSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.double(let a), .double(let b)): a.bitPattern == b.bitPattern // NaN- and -0-safe
        case (.string(let a), .string(let b)): a == b
        case (.document(let a), .document(let b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let a), .array(let b)): a == b
        case (.binary(let at, let ad), .binary(let bt, let bd)): at == bt && ad == bd
        case (.objectID(let a), .objectID(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.date(let a), .date(let b)): a == b
        case (.null, .null): true
        case (.regex(let ap, let ao), .regex(let bp, let bo)): ap == bp && ao == bo
        case (.javascript(let a), .javascript(let b)): a == b
        case (.int32(let a), .int32(let b)): a == b
        case (.timestamp(let a), .timestamp(let b)): a == b
        case (.int64(let a), .int64(let b)): a == b
        case (.decimal128(let al, let ah), .decimal128(let bl, let bh)): al == bl && ah == bh
        case (.minKey, .minKey): true
        case (.maxKey, .maxKey): true
        default: false
        }
    }
}

enum BSONCodecError: Error, Equatable {
    case nulInKey
    case truncated
    case invalidDocumentLength
    case invalidElementType(UInt8)
    case invalidString
    case invalidBoolean
    case invalidObjectID
    case trailingBytes
}

/// Byte-level BSON writer. Never emits deprecated types.
enum BSONWriter {
    static func encode(document pairs: [(key: String, value: BSONValue)]) throws -> Data {
        var body: [UInt8] = []
        for pair in pairs {
            try appendElement(key: pair.key, value: pair.value, to: &body)
        }
        var out: [UInt8] = []
        appendInt32(Int32(body.count + 5), to: &out)
        out.append(contentsOf: body)
        out.append(0)
        return Data(out)
    }

    private static func appendElement(key: String, value: BSONValue, to out: inout [UInt8]) throws {
        let keyBytes = Array(key.utf8)
        guard !keyBytes.contains(0) else { throw BSONCodecError.nulInKey }

        switch value {
        case .double(let double):
            out.append(0x01)
            out.append(contentsOf: keyBytes); out.append(0)
            appendUInt64(double.bitPattern, to: &out)
        case .string(let string):
            out.append(0x02)
            out.append(contentsOf: keyBytes); out.append(0)
            appendString(string, to: &out)
        case .document(let pairs):
            out.append(0x03)
            out.append(contentsOf: keyBytes); out.append(0)
            let nested = try encode(document: pairs)
            out.append(contentsOf: nested)
        case .array(let values):
            out.append(0x04)
            out.append(contentsOf: keyBytes); out.append(0)
            let nested = try encode(document: values.enumerated().map { (String($0.offset), $0.element) })
            out.append(contentsOf: nested)
        case .binary(let subtype, let data):
            out.append(0x05)
            out.append(contentsOf: keyBytes); out.append(0)
            appendInt32(Int32(data.count), to: &out)
            out.append(subtype)
            out.append(contentsOf: data)
        case .objectID(let data):
            guard data.count == 12 else { throw BSONCodecError.invalidObjectID }
            out.append(0x07)
            out.append(contentsOf: keyBytes); out.append(0)
            out.append(contentsOf: data)
        case .bool(let bool):
            out.append(0x08)
            out.append(contentsOf: keyBytes); out.append(0)
            out.append(bool ? 1 : 0)
        case .date(let milliseconds):
            out.append(0x09)
            out.append(contentsOf: keyBytes); out.append(0)
            appendInt64(milliseconds, to: &out)
        case .null:
            out.append(0x0A)
            out.append(contentsOf: keyBytes); out.append(0)
        case .regex(let pattern, let options):
            out.append(0x0B)
            out.append(contentsOf: keyBytes); out.append(0)
            let patternBytes = Array(pattern.utf8)
            let optionsBytes = Array(options.utf8)
            guard !patternBytes.contains(0), !optionsBytes.contains(0) else { throw BSONCodecError.nulInKey }
            out.append(contentsOf: patternBytes); out.append(0)
            out.append(contentsOf: optionsBytes); out.append(0)
        case .javascript(let code):
            out.append(0x0D)
            out.append(contentsOf: keyBytes); out.append(0)
            appendString(code, to: &out)
        case .int32(let int):
            out.append(0x10)
            out.append(contentsOf: keyBytes); out.append(0)
            appendInt32(int, to: &out)
        case .timestamp(let raw):
            out.append(0x11)
            out.append(contentsOf: keyBytes); out.append(0)
            appendUInt64(raw, to: &out)
        case .int64(let int):
            out.append(0x12)
            out.append(contentsOf: keyBytes); out.append(0)
            appendInt64(int, to: &out)
        case .decimal128(let low, let high):
            out.append(0x13)
            out.append(contentsOf: keyBytes); out.append(0)
            appendUInt64(low, to: &out)
            appendUInt64(high, to: &out)
        case .minKey:
            out.append(0xFF)
            out.append(contentsOf: keyBytes); out.append(0)
        case .maxKey:
            out.append(0x7F)
            out.append(contentsOf: keyBytes); out.append(0)
        }
    }

    private static func appendString(_ string: String, to out: inout [UInt8]) {
        let bytes = Array(string.utf8)
        appendInt32(Int32(bytes.count + 1), to: &out)
        out.append(contentsOf: bytes)
        out.append(0)
    }

    private static func appendInt32(_ value: Int32, to out: inout [UInt8]) {
        out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendInt64(_ value: Int64, to out: inout [UInt8]) {
        out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }

    private static func appendUInt64(_ value: UInt64, to out: inout [UInt8]) {
        out.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
}

/// Byte-level BSON reader with strict bounds checking. Deprecated server-side
/// types degrade gracefully (undefined → null, symbol → string, code-with-scope
/// → code); only dbPointer is rejected outright.
struct BSONReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    /// Reads one top-level document and requires the input to end exactly there.
    mutating func readDocument() throws -> [(key: String, value: BSONValue)] {
        let document = try readNestedDocument()
        guard offset == bytes.count else { throw BSONCodecError.trailingBytes }
        return document
    }

    private mutating func readNestedDocument() throws -> [(key: String, value: BSONValue)] {
        let length = Int(try readInt32())
        guard length >= 5, offset - 4 + length <= bytes.count else {
            throw BSONCodecError.invalidDocumentLength
        }
        let end = offset - 4 + length
        var pairs: [(key: String, value: BSONValue)] = []
        while true {
            guard offset < end else { throw BSONCodecError.invalidDocumentLength }
            let type = bytes[offset]
            offset += 1
            if type == 0 {
                guard offset == end else { throw BSONCodecError.invalidDocumentLength }
                return pairs
            }
            let key = try readCString()
            let value = try readValue(type: type)
            pairs.append((key, value))
        }
    }

    private mutating func readValue(type: UInt8) throws -> BSONValue {
        switch type {
        case 0x01:
            return .double(Double(bitPattern: try readUInt64()))
        case 0x02:
            return .string(try readString())
        case 0x03:
            return .document(try readNestedDocument())
        case 0x04:
            let pairs = try readNestedDocument()
            return .array(pairs.map(\.value))
        case 0x05:
            let length = Int(try readInt32())
            let subtype = try readByte()
            if subtype == 0x02 {
                // Deprecated "old binary": length wraps an inner int32 + payload.
                guard length >= 4 else { throw BSONCodecError.truncated }
                let inner = Int(try readInt32())
                guard inner == length - 4 else { throw BSONCodecError.invalidDocumentLength }
                return .binary(subtype: subtype, data: try readData(count: inner))
            }
            return .binary(subtype: subtype, data: try readData(count: length))
        case 0x06: // deprecated undefined
            return .null
        case 0x07:
            return .objectID(try readData(count: 12))
        case 0x08:
            let byte = try readByte()
            guard byte <= 1 else { throw BSONCodecError.invalidBoolean }
            return .bool(byte == 1)
        case 0x09:
            return .date(milliseconds: try readInt64())
        case 0x0A:
            return .null
        case 0x0B:
            return .regex(pattern: try readCString(), options: try readCString())
        case 0x0C:
            throw BSONCodecError.invalidElementType(type)
        case 0x0D:
            return .javascript(try readString())
        case 0x0E: // deprecated symbol
            return .string(try readString())
        case 0x0F: // deprecated code-with-scope: keep the code, drop the scope
            let totalLength = Int(try readInt32())
            guard totalLength >= 14, offset - 4 + totalLength <= bytes.count else {
                throw BSONCodecError.invalidDocumentLength
            }
            let end = offset - 4 + totalLength
            let code = try readString()
            _ = try readNestedDocument()
            guard offset == end else { throw BSONCodecError.invalidDocumentLength }
            return .javascript(code)
        case 0x10:
            return .int32(try readInt32())
        case 0x11:
            return .timestamp(raw: try readUInt64())
        case 0x12:
            return .int64(try readInt64())
        case 0x13:
            let low = try readUInt64()
            let high = try readUInt64()
            return .decimal128(low: low, high: high)
        case 0xFF:
            return .minKey
        case 0x7F:
            return .maxKey
        default:
            throw BSONCodecError.invalidElementType(type)
        }
    }

    private mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw BSONCodecError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= bytes.count else { throw BSONCodecError.truncated }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    private mutating func readInt32() throws -> Int32 {
        let raw = try readData(count: 4)
        return raw.withUnsafeBytes { $0.load(as: Int32.self) }.littleEndian
    }

    private mutating func readInt64() throws -> Int64 {
        let raw = try readData(count: 8)
        return raw.withUnsafeBytes { $0.load(as: Int64.self) }.littleEndian
    }

    private mutating func readUInt64() throws -> UInt64 {
        let raw = try readData(count: 8)
        return raw.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }

    private mutating func readString() throws -> String {
        let length = Int(try readInt32())
        guard length >= 1, offset + length <= bytes.count, bytes[offset + length - 1] == 0 else {
            throw BSONCodecError.invalidString
        }
        defer { offset += length }
        return String(decoding: bytes[offset..<offset + length - 1], as: UTF8.self)
    }

    private mutating func readCString() throws -> String {
        guard let nul = bytes[offset...].firstIndex(of: 0) else { throw BSONCodecError.truncated }
        defer { offset = nul + 1 }
        return String(decoding: bytes[offset..<nul], as: UTF8.self)
    }
}
