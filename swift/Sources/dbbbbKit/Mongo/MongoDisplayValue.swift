import Foundation
import dbbbbCore

/// BSON → display-safe value conversion for MongoDB results.
///
/// Wire shape follows the Electron reference (canonical Extended JSON parsed
/// into objects): ObjectId, Decimal128, Binary, Int64, Timestamp, Regex, dates
/// and the key sentinels cross as `$`-tagged objects (dates as ISO-8601
/// strings inside `$date`, keeping them precision-safe *and* round-trippable
/// for editing); int32 and finite doubles cross as plain numbers.
enum MongoDisplayValue {
    private static let maxValueBytes = 8 * 1024 * 1024

    static func convert(document pairs: [(key: String, value: BSONValue)]) -> DisplayValue {
        convert(.document(pairs))
    }

    static func convert(_ value: BSONValue) -> DisplayValue {
        switch value {
        case .double(let double):
            if double.isNaN { return tag("numberDouble", .string("NaN")) }
            if double == .infinity { return tag("numberDouble", .string("Infinity")) }
            if double == -.infinity { return tag("numberDouble", .string("-Infinity")) }
            return .number(double)
        case .string(let string):
            return .string(bounded(string))
        case .document(let pairs):
            return .object(pairs.map { (key: $0.key, value: convert($0.value)) })
        case .array(let values):
            return .array(values.map { convert($0) })
        case .binary(let subtype, let data):
            let subtypeText = String(subtype, radix: 16)
            let padded = subtypeText.count == 1 ? "0" + subtypeText : subtypeText
            return tag("binary", .object([
                (key: "base64", value: .string(bounded(data.base64EncodedString()))),
                (key: "subType", value: .string(padded)),
            ]))
        case .objectID(let data):
            return tag("oid", .string(data.map { String(format: "%02x", $0) }.joined()))
        case .bool(let bool):
            return .bool(bool)
        case .date(let milliseconds):
            return tag("date", .string(isoString(milliseconds: milliseconds)))
        case .null:
            return .null
        case .regex(let pattern, let options):
            return tag("regularExpression", .object([
                (key: "pattern", value: .string(bounded(pattern))),
                (key: "options", value: .string(options)),
            ]))
        case .javascript(let code):
            return tag("code", .string(bounded(code)))
        case .int32(let int):
            return .number(Double(int))
        case .timestamp(let raw):
            return tag("timestamp", .object([
                (key: "t", value: .number(Double(raw >> 32))),
                (key: "i", value: .number(Double(raw & 0xFFFF_FFFF))),
            ]))
        case .int64(let int):
            // Precision-sensitive: bigints cross as tagged strings, never as Double.
            return tag("numberLong", .string(String(int)))
        case .decimal128(let low, let high):
            return tag("numberDecimal", .string(Decimal128Codec.toString(low: low, high: high)))
        case .minKey:
            return tag("minKey", .number(1))
        case .maxKey:
            return tag("maxKey", .number(1))
        }
    }

    private static func tag(_ name: String, _ value: DisplayValue) -> DisplayValue {
        .object([(key: "$\(name)", value: value)])
    }

    static func isoString(milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.ISO8601Format(.init(includingFractionalSeconds: true))
    }

    /// A single oversized value must not materialize in full before the
    /// document byte budget applies; truncate it and mark it visibly.
    static func bounded(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxValueBytes else { return text }
        let kept = String(decoding: utf8[0..<maxValueBytes], as: UTF8.self)
        return kept + "…[dbbbb truncated \(utf8.count - maxValueBytes) bytes]"
    }
}
