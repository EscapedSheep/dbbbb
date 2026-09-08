import Foundation
import dbbbbCore

/// Errors raised while planning a single-document change. These are
/// review-facing messages; they never contain credentials.
struct MongoChangePlanError: dbbbbError, Equatable {
    let reason: String
    var userMessage: String { reason }
}

/// One ordered field/value pair of a document snapshot.
typealias MongoFieldEntry = (field: String, value: BSONValue)

/// A planned single-document update: the optimistic-concurrency filter plus
/// the `$set`/`$unset` payload (at least one of the two is non-empty).
struct MongoUpdatePlan {
    let filter: [(key: String, value: BSONValue)]
    let set: [(key: String, value: BSONValue)]
    let unset: [String]
}

// Tuple associated values do not synthesize Equatable.
extension MongoUpdatePlan: Equatable {
    static func == (lhs: MongoUpdatePlan, rhs: MongoUpdatePlan) -> Bool {
        func pairsEqual(
            _ left: [(key: String, value: BSONValue)],
            _ right: [(key: String, value: BSONValue)]
        ) -> Bool {
            left.count == right.count
                && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }
        return pairsEqual(lhs.filter, rhs.filter)
            && pairsEqual(lhs.set, rhs.set)
            && lhs.unset == rhs.unset
    }
}

/// Pure planner for safe single-document MongoDB changes (optimistic
/// concurrency), ported from `planMongoUpdate` in
/// `src/main/editing/change-planner.ts` and the Electron adapter's
/// `mongoDeleteFilter`: the filter compares *every* original field with its
/// original value (nulls match only existing nulls), `_id` is required and
/// immutable, and a zero `matchedCount`/`deletedCount` at apply time means
/// the document changed or vanished underneath the edit.
///
/// `$set` values keep the BSON numeric width of the field they replace:
/// a double field crosses the display layer as a bare `.number`, so an
/// integral edit would otherwise be written back as int32 (see
/// `jsonValue(from:)`), silently changing the field's BSON type. The planner
/// re-encodes such edits as double. Tagged int32/int64 originals keep their
/// width; an int32 field only widens to int64 when the new value does not
/// fit in 32 bits, which is unavoidable.
enum MongoChangePlanner {
    /// JS-era prototype-pollution guards; record keys still come from a UI
    /// round-trip and are never valid field choices for us.
    static let dangerousFieldNames: Set<String> = ["__proto__", "constructor", "prototype"]

    // MARK: - DisplayValue → BSON

    /// Converts one displayed value back to BSON through the canonical EJSON
    /// codec, so `$`-tagged display shapes (`$oid`, `$numberLong`,
    /// `$numberDecimal`, `$date`, `$binary`, …) become their BSON types and
    /// plain values stay plain.
    static func bsonValue(from displayValue: DisplayValue, label: String) throws -> BSONValue {
        let json = try jsonValue(from: displayValue, label: label)
        var converter = EJSON.Converter()
        return try converter.convert(json, depth: 0)
    }

    private static func jsonValue(from value: DisplayValue, label: String) throws -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let flag):
            return .bool(flag)
        case .number(let number):
            guard number.isFinite else {
                throw MongoChangePlanError(reason: "\(label) contains a non-finite number.")
            }
            if number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return .number(String(Int64(number)))
            }
            return .number(String(number))
        case .string(let text):
            return .string(text)
        case .binary:
            // MongoDB binary crosses as a `$binary` tag, never as tagged data.
            throw MongoChangePlanError(
                reason: "\(label) contains a value that is not valid MongoDB Extended JSON.")
        case .array(let values):
            return .array(try values.map { try jsonValue(from: $0, label: label) })
        case .object(let pairs):
            return .object(try pairs.map { ($0.key, try jsonValue(from: $0.value, label: label)) })
        }
    }

    // MARK: - Record mapping

    /// Folds a UI record into validated field entries with BSON values.
    static func documentEntries(
        _ record: [String: DisplayValue],
        label: String
    ) throws -> [MongoFieldEntry] {
        try record.map { field, value in
            try validateFieldName(field, label: label)
            return (field, try bsonValue(from: value, label: "\(label).\(field)"))
        }
    }

    private static func validateFieldName(_ field: String, label: String) throws {
        if field.isEmpty || field.contains("\0")
            || field.contains(".") || field.contains("$")
            || dangerousFieldNames.contains(field) {
            throw MongoChangePlanError(reason: "\(label) contains an unsafe MongoDB field name.")
        }
    }

    private static func validatedEntries(
        _ entries: [MongoFieldEntry], label: String
    ) throws -> [MongoFieldEntry] {
        var seen: Set<String> = []
        for (field, _) in entries {
            try validateFieldName(field, label: label)
            guard seen.insert(field).inserted else {
                throw MongoChangePlanError(reason: "\(label) contains a duplicate field name.")
            }
        }
        return entries
    }

    private static func entryMap(_ entries: [MongoFieldEntry]) -> [String: BSONValue] {
        Dictionary(entries.map { ($0.field, $0.value) }) { first, _ in first }
    }

    /// Null fields match only an explicit null that still exists.
    private static func originalCondition(_ value: BSONValue) -> BSONValue {
        switch value {
        case .null:
            return .document([("$eq", .null), ("$exists", .bool(true))])
        default:
            return .document([("$eq", value)])
        }
    }

    // MARK: - Plans

    /// Re-encodes an edited value so an integral edit cannot silently change a
    /// double field's BSON type: when the original field is a double (shown as
    /// a bare `.number`) and the new value is an integral int32/int64, the
    /// `$set` value stays a double. The conversion is lossless — integral
    /// display numbers are exactly representable as Double. All other
    /// combinations (including explicitly tagged `$numberInt`/`$numberLong`
    /// edits, which this rule deliberately overrides back to double to keep
    /// the drift fail-safe) pass through unchanged.
    private static func valuePreservingNumericType(
        original: BSONValue, current: BSONValue
    ) -> BSONValue {
        switch (original, current) {
        case (.double, .int32(let int)):
            return .double(Double(int))
        case (.double, .int64(let int)):
            return .double(Double(int))
        default:
            return current
        }
    }

    /// Plans one top-level, single-document update. The filter compares every
    /// original field with its original value — the same whole-document
    /// optimistic granularity as deletes and PostgreSQL full-row changes.
    /// Fields added in `current` must still be absent, which prevents
    /// silently overwriting a concurrent insert.
    static func planUpdate(
        original: [MongoFieldEntry],
        current: [MongoFieldEntry]
    ) throws -> MongoUpdatePlan {
        let originalEntries = try validatedEntries(original, label: "MongoDB original document")
        let currentEntries = try validatedEntries(current, label: "MongoDB current document")
        let originalValues = entryMap(originalEntries)
        let currentValues = entryMap(currentEntries)

        guard let originalID = originalValues["_id"], let currentID = currentValues["_id"] else {
            throw MongoChangePlanError(
                reason: "A MongoDB single-document update requires _id in both documents.")
        }
        guard originalID == currentID else {
            throw MongoChangePlanError(reason: "MongoDB _id cannot be edited.")
        }

        var set: [(key: String, value: BSONValue)] = []
        var unset: [String] = []
        for (field, originalValue) in originalEntries where field != "_id" {
            if let currentValue = currentValues[field] {
                if currentValue != originalValue {
                    set.append((field, valuePreservingNumericType(
                        original: originalValue, current: currentValue)))
                }
            } else {
                unset.append(field)
            }
        }
        for (field, currentValue) in currentEntries where field != "_id" && originalValues[field] == nil {
            set.append((field, currentValue))
        }
        guard !set.isEmpty || !unset.isEmpty else {
            throw MongoChangePlanError(
                reason: "A MongoDB update must contain at least one changed or removed field.")
        }

        var filter: [(key: String, value: BSONValue)] = [("_id", .document([("$eq", originalID)]))]
        for (field, originalValue) in originalEntries where field != "_id" {
            filter.append((field, originalCondition(originalValue)))
        }
        for (field, _) in currentEntries where field != "_id" && originalValues[field] == nil {
            filter.append((field, .document([("$exists", .bool(false))])))
        }
        return MongoUpdatePlan(filter: filter, set: set, unset: unset)
    }

    /// Plans one optimistic single-document delete as a filter over every
    /// original field.
    static func planDeleteFilter(
        original: [MongoFieldEntry]
    ) throws -> [(key: String, value: BSONValue)] {
        let entries = try validatedEntries(original, label: "MongoDB original document")
        guard entries.contains(where: { $0.field == "_id" }) else {
            throw MongoChangePlanError(
                reason: "A MongoDB single-document delete requires _id in the original document.")
        }
        return entries.map { ($0.field, originalCondition($0.value)) }
    }

    /// Plans one document insert: the reviewed field/value pairs converted to
    /// BSON through the canonical EJSON codec, with the same field-name
    /// validation as updates. `_id` may be given explicitly (tagged EJSON
    /// shapes like `$oid` keep their BSON type); when it is absent the server
    /// generates an ObjectId. An empty document is valid.
    static func planInsert(
        _ record: [String: DisplayValue]
    ) throws -> [(key: String, value: BSONValue)] {
        try documentEntries(record, label: "MongoDB inserted document")
            .map { (key: $0.field, value: $0.value) }
    }
}
