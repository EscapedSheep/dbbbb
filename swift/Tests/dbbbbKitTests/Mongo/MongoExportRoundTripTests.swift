import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit

/// Export → import round-trip fidelity for MongoDB document results: the
/// JSONL export goes through the canonical EJSON layer, so feeding the
/// exported lines back into `MongoImportPlanner` (the import path's parser)
/// must reproduce the original BSON values bit-for-bit.
struct MongoExportRoundTripTests {
    private let meta = ResultMeta(count: 0, truncated: false, elapsedMilliseconds: 0)
    private let objectID = Data([0x64, 0xB7, 0xF3, 0xC2, 0xE9, 0xB0, 0xA5, 0xD4, 0xC3, 0xB2, 0xA1, 0x90])

    /// Tuple pairs do not synthesize Equatable.
    private func pairsEqual(
        _ left: [(key: String, value: BSONValue)],
        _ right: [(key: String, value: BSONValue)]
    ) -> Bool {
        left.count == right.count
            && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    /// Displays one BSON document exactly as a query result would, exports it
    /// as JSONL, and re-parses every line through the import planner.
    private func exportAndReimport(
        _ document: [(key: String, value: BSONValue)]
    ) throws -> (text: String, reimported: [(key: String, value: BSONValue)]) {
        let displayed = MongoDisplayValue.convert(document: document)
        let exported = try ResultExporter.exportData(for: .documents([displayed], meta: meta))
        let text = String(decoding: exported.data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 1)
        let reimported = try MongoImportPlanner.document(line: 1, content: lines[0])
        return (text, reimported)
    }

    @Test func bsonTypesSurviveExportAndReimport() throws {
        let decimal = try #require(Decimal128Codec.fromString("0.1"))
        let document: [(key: String, value: BSONValue)] = [
            ("_id", .objectID(objectID)),
            ("rating", .double(5.0)), // integral double: must stay double
            ("score", .double(2.5)),
            ("big", .int64(9_007_199_254_740_993)),
            ("price", .decimal128(low: decimal.low, high: decimal.high)),
            ("when", .date(milliseconds: 1_700_000_000_000)),
            ("ts", .timestamp(raw: (7 << 32) | 3)),
            ("bin", .binary(subtype: 0x80, data: Data([1, 2, 3]))),
            ("re", .regex(pattern: "^ab+c$", options: "ix")),
            ("inf", .double(.infinity)),
            ("lo", .minKey),
            ("hi", .maxKey),
            ("nested", .document([("z", .double(1.5)), ("a", .string("x"))])),
            ("tags", .array([.int64(2), .string("s"), .null])),
        ]
        let (_, reimported) = try exportAndReimport(document)
        #expect(pairsEqual(reimported, document))
    }

    @Test func exportedTextKeepsKeyOrderAndDoubleTags() throws {
        let document: [(key: String, value: BSONValue)] = [
            ("_id", .objectID(objectID)),
            ("rating", .double(5.0)),
            ("big", .int64(9_007_199_254_740_993)),
            ("when", .date(milliseconds: 1_700_000_000_000)),
            ("nested", .document([("z", .double(1.5)), ("a", .string("x"))])),
        ]
        let (text, _) = try exportAndReimport(document)
        // Key order is the original BSON order (never sorted); bare display
        // numbers become $numberDouble; tagged values pass through verbatim.
        #expect(text == "{\"_id\":{\"$oid\":\"64b7f3c2e9b0a5d4c3b2a190\"}"
            + ",\"rating\":{\"$numberDouble\":\"5.0\"}"
            + ",\"big\":{\"$numberLong\":\"9007199254740993\"}"
            + ",\"when\":{\"$date\":\"2023-11-14T22:13:20.000Z\"}"
            + ",\"nested\":{\"z\":{\"$numberDouble\":\"1.5\"},\"a\":\"x\"}}\n")
    }

    @Test func timestampTagKeepsIntegerPayload() throws {
        // $timestamp t/i cross the display layer as plain numbers; the export
        // must render them as raw JSON integers, not $numberDouble, or the
        // import side rejects the tag payload.
        let (text, reimported) = try exportAndReimport([
            ("ts", .timestamp(raw: (1_565_545_664 << 32) | 1)),
        ])
        #expect(text == #"{"ts":{"$timestamp":{"t":1565545664,"i":1}}}"# + "\n")
        #expect(pairsEqual(reimported, [("ts", .timestamp(raw: (1_565_545_664 << 32) | 1))]))
    }

    @Test func int32ReimportsWidenedToDouble() throws {
        // Documented trade-off: BSON int32 crosses the display layer as a bare
        // `.number`, indistinguishable from a double, so the export emits
        // $numberDouble and a re-import widens the field to double. Keeping
        // int32 exact would require a display-layer wire-shape change.
        let (_, reimported) = try exportAndReimport([("n", .int32(5))])
        #expect(pairsEqual(reimported, [("n", .double(5.0))]))
    }

    @Test func codeTagExportsButStaysFailClosedOnImport() throws {
        let displayed = DisplayValue.object([
            ("script", .object([("$code", .string("function() { return 1; }"))])),
        ])
        let exported = try ResultExporter.exportData(for: .documents([displayed], meta: meta))
        let text = String(decoding: exported.data, as: UTF8.self)
        #expect(text == "{\"script\":{\"$code\":\"function() { return 1; }\"}}\n")
        // Import stays fail-closed for code tags.
        do {
            _ = try MongoImportPlanner.document(line: 1, content: String(text.dropLast()))
            Issue.record("expected the $code line to be rejected on import")
        } catch let error as ImportError {
            guard case .parseFailure = error else {
                Issue.record("expected parseFailure, got \(error)")
                return
            }
        }
    }

    @Test func displayValueCodablePreservesObjectKeyOrder() throws {
        // Export fidelity relies on DisplayValue.object keeping its pair order
        // across the Codable round-trip (Model.swift decodes pairs with
        // `compactMap`, which drops malformed entries but never reorders).
        let value = DisplayValue.object([
            ("z", .number(1)),
            ("a", .object([("y", .null), ("b", .bool(true))])),
            ("m", .array([.string("s")])),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(DisplayValue.self, from: data)
        guard case .object(let pairs) = decoded else {
            Issue.record("expected object, got \(decoded)")
            return
        }
        #expect(pairs.map(\.key) == ["z", "a", "m"])
        guard case .object(let nested) = pairs[1].value else {
            Issue.record("expected nested object, got \(pairs[1].value)")
            return
        }
        #expect(nested.map(\.key) == ["y", "b"])
        #expect(decoded == value)
    }
}
