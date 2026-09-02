import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

/// Unit tests for the pure MongoDB change planner: DisplayValue → BSON
/// round-trips, whole-document optimistic filters, and `$set`/`$unset`
/// payloads.
struct MongoChangePlannerTests {
    private func assertPlanThrows(
        containing fragment: String,
        _ body: () throws -> some Any
    ) {
        do {
            _ = try body()
            Issue.record("Expected planner to throw")
        } catch let error as MongoChangePlanError {
            #expect(
                error.userMessage.contains(fragment),
                "\(error.userMessage) should contain \(fragment)")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    private let objectID = Data(repeating: 0xAB, count: 12)

    /// Tuple pairs do not synthesize Equatable.
    private func pairsEqual(
        _ left: [(key: String, value: BSONValue)],
        _ right: [(key: String, value: BSONValue)]
    ) -> Bool {
        left.count == right.count
            && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    // MARK: DisplayValue → BSON

    @Test func taggedDisplayShapesRoundTrip() throws {
        // $oid
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$oid", .string("abababababababababababab"))]), label: "d")
                == .objectID(objectID))
        // $numberLong stays a 64-bit integer, never a Double.
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$numberLong", .string("9007199254740993"))]), label: "d")
                == .int64(9_007_199_254_740_993))
        // $numberDecimal keeps its exact bits.
        let decimal = try MongoChangePlanner.bsonValue(
            from: .object([("$numberDecimal", .string("0.1"))]), label: "d")
        guard case .decimal128(let low, let high) = decimal else {
            Issue.record("expected decimal128, got \(decimal)")
            return
        }
        #expect(Decimal128Codec.toString(low: low, high: high) == "0.1")
        // $date ISO strings come back as BSON dates.
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$date", .string("2023-11-14T22:13:20.000Z"))]), label: "d")
                == .date(milliseconds: 1_700_000_000_000))
        // $binary, $timestamp, min/max key.
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$binary", .object([
                    ("base64", .string("AQID")), ("subType", .string("80"))]))]), label: "d")
                == .binary(subtype: 0x80, data: Data([1, 2, 3])))
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$timestamp", .object([("t", .number(7)), ("i", .number(3))]))]),
                label: "d")
                == .timestamp(raw: (7 << 32) | 3))
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .object([("$minKey", .number(1))]), label: "d") == .minKey)
    }

    @Test func plainDisplayShapesConvert() throws {
        #expect(try MongoChangePlanner.bsonValue(from: .null, label: "d") == .null)
        #expect(try MongoChangePlanner.bsonValue(from: .bool(true), label: "d") == .bool(true))
        #expect(try MongoChangePlanner.bsonValue(from: .string("hi"), label: "d") == .string("hi"))
        // Integral numbers convert to int32, fractional to double.
        #expect(try MongoChangePlanner.bsonValue(from: .number(42), label: "d") == .int32(42))
        #expect(try MongoChangePlanner.bsonValue(from: .number(1.5), label: "d") == .double(1.5))
        #expect(
            try MongoChangePlanner.bsonValue(
                from: .array([.number(2), .string("x")]), label: "d")
                == .array([.int32(2), .string("x")]))
        // Nested documents keep their key order.
        let nested = try MongoChangePlanner.bsonValue(
            from: .object([("b", .number(1)), ("a", .number(2))]), label: "d")
        guard case .document(let pairs) = nested else {
            Issue.record("expected document, got \(nested)")
            return
        }
        #expect(pairs.map(\.key) == ["b", "a"])
    }

    @Test func invalidDisplayValuesAreRejected() {
        assertPlanThrows(containing: "non-finite number") {
            try MongoChangePlanner.bsonValue(from: .number(.nan), label: "d")
        }
        assertPlanThrows(containing: "not valid MongoDB Extended JSON") {
            try MongoChangePlanner.bsonValue(from: .binary(Data([1])), label: "d")
        }
    }

    // MARK: documentEntries

    @Test func documentEntriesRejectUnsafeFieldNames() {
        for field in ["a.b", "$set", "a$b", "__proto__", "constructor", "", "a\0b"] {
            assertPlanThrows(containing: "unsafe MongoDB field name") {
                try MongoChangePlanner.documentEntries([field: .number(1)], label: "MongoDB original document")
            }
        }
    }

    // MARK: planUpdate

    @Test func updatePlanMatchesEveryOriginalFieldAndSetsOnlyChanges() throws {
        let plan = try MongoChangePlanner.planUpdate(
            original: [
                ("_id", .objectID(objectID)),
                ("name", .string("before")),
                ("note", .null),
                ("count", .int32(4)),
            ],
            current: [
                ("_id", .objectID(objectID)),
                ("name", .string("after")),
                ("note", .null),
                ("count", .int32(4)),
            ])

        #expect(pairsEqual(plan.filter, [
            ("_id", .document([("$eq", .objectID(objectID))])),
            ("name", .document([("$eq", .string("before"))])),
            ("note", .document([("$eq", .null), ("$exists", .bool(true))])),
            ("count", .document([("$eq", .int32(4))])),
        ]))
        #expect(pairsEqual(plan.set, [("name", .string("after"))]))
        #expect(plan.unset.isEmpty)
    }

    @Test func updatePlanUnsetsRemovedFields() throws {
        let plan = try MongoChangePlanner.planUpdate(
            original: [("_id", .int32(1)), ("keep", .bool(true)), ("drop", .string("x"))],
            current: [("_id", .int32(1)), ("keep", .bool(true))])
        #expect(plan.unset == ["drop"])
        #expect(plan.set.isEmpty)
    }

    @Test func updatePlanRequiresAddedFieldsToStillBeAbsent() throws {
        let plan = try MongoChangePlanner.planUpdate(
            original: [("_id", .int32(1))],
            current: [("_id", .int32(1)), ("added", .string("new"))])
        #expect(pairsEqual(plan.set, [("added", .string("new"))]))
        #expect(plan.filter.contains { $0.key == "added" && $0.value == .document([("$exists", .bool(false))]) })
    }

    @Test func updatePlanValidation() {
        let id: MongoFieldEntry = ("_id", .int32(1))
        assertPlanThrows(containing: "requires _id in both documents") {
            try MongoChangePlanner.planUpdate(original: [("a", .int32(1))], current: [id])
        }
        assertPlanThrows(containing: "_id cannot be edited") {
            try MongoChangePlanner.planUpdate(
                original: [id, ("a", .int32(1))],
                current: [("_id", .int32(2)), ("a", .int32(1))])
        }
        assertPlanThrows(containing: "at least one changed or removed field") {
            try MongoChangePlanner.planUpdate(original: [id], current: [id])
        }
        assertPlanThrows(containing: "duplicate field name") {
            try MongoChangePlanner.planUpdate(original: [id, id], current: [id])
        }
    }

    // MARK: planDeleteFilter

    @Test func deleteFilterMatchesEveryOriginalField() throws {
        let filter = try MongoChangePlanner.planDeleteFilter(original: [
            ("_id", .objectID(objectID)),
            ("name", .string("before")),
            ("note", .null),
        ])
        #expect(pairsEqual(filter, [
            ("_id", .document([("$eq", .objectID(objectID))])),
            ("name", .document([("$eq", .string("before"))])),
            ("note", .document([("$eq", .null), ("$exists", .bool(true))])),
        ]))
    }

    @Test func deleteFilterRequiresID() {
        assertPlanThrows(containing: "requires _id in the original document") {
            try MongoChangePlanner.planDeleteFilter(original: [("name", .string("x"))])
        }
    }
}
