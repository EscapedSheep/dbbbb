import Foundation
import Testing
@testable import dbbbbKit

struct EJSONTests {
    // MARK: Canonical tag round-trips (text → BSONValue → BSON bytes → text)

    private func assertRoundTrip(_ input: String, expectedCanonical: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var converter = EJSON.Converter()
        let json = try EJSON.parseJSON(input)
        let value = try converter.convert(json, depth: 0)

        // BSON byte round-trip.
        guard case .document(let pairs) = value else {
            Issue.record("top level must be a document", sourceLocation: sourceLocation)
            return
        }
        let bytes = try BSONWriter.encode(document: pairs)
        var reader = BSONReader(data: bytes)
        let decoded = try reader.readDocument()
        #expect(BSONValue.document(decoded) == value, "BSON byte round-trip", sourceLocation: sourceLocation)

        // EJSON text round-trip.
        let canonical = EJSONSerializer.serialize(document: decoded)
        if let expectedCanonical {
            #expect(canonical == expectedCanonical, sourceLocation: sourceLocation)
        }
        var reparsed = EJSON.Converter()
        let reparsedValue = try reparsed.convert(EJSON.parseJSON(canonical), depth: 0)
        #expect(reparsedValue == value, "EJSON text round-trip of \(canonical)", sourceLocation: sourceLocation)
    }

    @Test func scalarTags() throws {
        try assertRoundTrip(#"{"_id":{"$oid":"64b7f3c2e9b0a5d4c3b2a190"}}"#)
        try assertRoundTrip(#"{"n":{"$numberLong":"9223372036854775807"}}"#)
        try assertRoundTrip(#"{"n":{"$numberLong":"-9223372036854775808"}}"#)
        try assertRoundTrip(#"{"i":{"$numberInt":"-2147483648"}}"#)
        try assertRoundTrip(#"{"d":{"$numberDouble":"1.5"}}"#)
        try assertRoundTrip(#"{"d":{"$numberDouble":"NaN"}}"#)
        try assertRoundTrip(#"{"d":{"$numberDouble":"Infinity"}}"#)
        try assertRoundTrip(#"{"d":{"$numberDouble":"-Infinity"}}"#)
        try assertRoundTrip(#"{"dec":{"$numberDecimal":"0.10"}}"#)
        try assertRoundTrip(#"{"dec":{"$numberDecimal":"9.999999999999999999999999999999999E+6111"}}"#)
        try assertRoundTrip(#"{"b":{"$binary":{"base64":"AAECAwQ=","subType":"00"}}}"#)
        try assertRoundTrip(#"{"b":{"$binary":{"base64":"iVBORw0KGgo=","subType":"80"}}}"#)
        try assertRoundTrip(#"{"r":{"$regularExpression":{"pattern":"^ab+c$","options":"ix"}}}"#)
        try assertRoundTrip(#"{"ts":{"$timestamp":{"t":1565545664,"i":1}}}"#)
        try assertRoundTrip(#"{"lo":{"$minKey":1},"hi":{"$maxKey":1}}"#)
    }

    @Test func dateForms() throws {
        // Canonical long form round-trips exactly.
        try assertRoundTrip(#"{"d":{"$date":{"$numberLong":"1700000000000"}}}"#)
        // ISO string form normalizes to the canonical long form.
        try assertRoundTrip(
            #"{"d":{"$date":"2023-11-14T22:13:20.000Z"}}"#,
            expectedCanonical: #"{"d":{"$date":{"$numberLong":"1700000000000"}}}"#
        )
        try assertRoundTrip(
            #"{"d":{"$date":"2023-11-14T22:13:20Z"}}"#,
            expectedCanonical: #"{"d":{"$date":{"$numberLong":"1700000000000"}}}"#
        )
    }

    @Test func plainNumbers() throws {
        // Untyped JSON integers pick the narrowest BSON int; decimals are doubles.
        try assertRoundTrip(#"{"a":5}"#, expectedCanonical: #"{"a":{"$numberInt":"5"}}"#)
        try assertRoundTrip(#"{"a":-2147483649}"#, expectedCanonical: #"{"a":{"$numberLong":"-2147483649"}}"#)
        try assertRoundTrip(#"{"a":1.5}"#, expectedCanonical: #"{"a":{"$numberDouble":"1.5"}}"#)
        try assertRoundTrip(#"{"a":true,"b":null}"#)
    }

    @Test func nestedDocumentsPreserveOrder() throws {
        let input = #"{"z":1,"a":{"y":[1,{"b":2,"c":3}],"x":{"$oid":"64b7f3c2e9b0a5d4c3b2a190"}}}"#
        var converter = EJSON.Converter()
        let value = try converter.convert(EJSON.parseJSON(input), depth: 0)
        guard case .document(let pairs) = value else {
            Issue.record("not a document")
            return
        }
        #expect(pairs.map(\.key) == ["z", "a"])
        guard case .document(let nested) = pairs[1].value else {
            Issue.record("not nested")
            return
        }
        #expect(nested.map(\.key) == ["y", "x"])
    }

    @Test func queryOperatorsAreOrdinaryDocuments() throws {
        // $-prefixed keys that are not EJSON tags must survive untouched.
        try assertRoundTrip(#"{"age":{"$gt":21}}"#)
        try assertRoundTrip(#"{"name":{"$regex":"^a","$options":"i"}}"#)
        try assertRoundTrip(#"{"$or":[{"a":1},{"b":2}]}"#)
    }

    // MARK: Rejections

    private func assertRejected(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var converter = EJSON.Converter()
        #expect(sourceLocation: sourceLocation) {
            _ = try converter.convert(EJSON.parseJSON(input), depth: 0)
        } throws: { _ in true }
    }

    @Test func dangerousKeysRejected() {
        assertRejected(#"{"__proto__":1}"#)
        assertRejected(#"{"a":{"constructor":1}}"#)
        assertRejected(#"{"a":[{"prototype":1}]}"#)
    }

    @Test func codeTagsRejected() {
        // Code never crosses: fail closed on JavaScript-bearing EJSON.
        assertRejected(#"{"$code":"function(){ return 1; }"}"#)
        assertRejected(#"{"a":{"$code":"x"}}"#)
        assertRejected(#"{"$undefined":true}"#)
        assertRejected(#"{"$symbol":"x"}"#)
    }

    @Test func invalidTagPayloadsRejected() {
        assertRejected(#"{"$oid":"zz"}"#)
        assertRejected(#"{"$oid":"64b7f3c2"}"#)
        assertRejected(#"{"$numberLong":"abc"}"#)
        assertRejected(#"{"$numberLong":"9223372036854775808"}"#)
        assertRejected(#"{"$numberInt":"2147483648"}"#)
        assertRejected(#"{"$numberDecimal":"1.2.3"}"#)
        assertRejected(#"{"$binary":{"base64":"!!!","subType":"00"}}"#)
        assertRejected(#"{"$binary":{"base64":"AAE=","subType":"zz"}}"#)
        assertRejected(#"{"$date":"not a date"}"#)
        assertRejected(#"{"$timestamp":{"t":-1,"i":1}}"#)
        assertRejected(#"{"$timestamp":{"t":4294967296,"i":1}}"#)
        assertRejected(#"{"n":123456789012345678901234567890}"#) // untyped int beyond int64
    }

    @Test(arguments: ["", "{", #"{"a":}"#, #"{"a":1,}"#, "[1,2", #"{"a" 1}"#, "tru", #"{"a":01}"#])
    func malformedJSONRejected(text: String) {
        #expect { try EJSON.parseJSON(text) } throws: { _ in true }
    }

    @Test func depthLimitEnforced() {
        var text = "1"
        for _ in 0..<(EJSON.maxDepth + 2) { text = "[" + text + "]" }
        assertRejected(text)
    }

    // MARK: find/aggregate entry points

    @Test func findFilterMustBeObject() throws {
        #expect { try EJSON.parseDocument("[1,2]", label: "A find filter") } throws: { error in
            (error as? EJSONError) == .expectedDocument("A find filter")
        }
        _ = try EJSON.parseDocument("{}", label: "A find filter")
    }

    @Test func pipelineShape() throws {
        #expect { try EJSON.parsePipeline("{}") } throws: { _ in true }
        #expect { try EJSON.parsePipeline("[1,2]") } throws: { error in
            (error as? EJSONError) == .stageNotDocument
        }
        _ = try EJSON.parsePipeline(#"[{"$match":{"a":1}}]"#)
    }

    // MARK: Pipeline write-stage guard

    @Test func writeStagesRejected() {
        #expect { try MongoAdapter.assertReadOnlyPipeline([
            .document([("$out", .string("target"))]),
        ]) } throws: { _ in true }
        #expect { try MongoAdapter.assertReadOnlyPipeline([
            .document([("$merge", .document([("into", .string("target"))]))]),
        ]) } throws: { _ in true }
    }

    @Test func multiKeyStageStillRejected() {
        // A write operator smuggled behind a read operator in the same stage.
        #expect { try MongoAdapter.assertReadOnlyPipeline([
            .document([("$match", .document([])), ("$out", .string("target"))]),
        ]) } throws: { error in
            (error as? MongoAdapterError) == .writeStageRejected("$out")
        }
    }

    @Test func readOnlyPipelineAccepted() throws {
        try MongoAdapter.assertReadOnlyPipeline([
            .document([("$match", .document([("a", .int32(1))]))]),
            .document([("$group", .document([("_id", .string("$a"))]))]),
            .document([("$sort", .document([("a", .int32(-1))]))]),
        ])
    }

    // MARK: Byte-level codec edge cases

    @Test func bsonRejectsNulInKey() {
        #expect { try BSONWriter.encode(document: [("a\0b", .int32(1))]) } throws: { _ in true }
    }

    @Test func bsonReaderRejectsTruncation() throws {
        let bytes = try BSONWriter.encode(document: [("a", .string("hello"))])
        var reader = BSONReader(data: bytes.dropLast(3))
        #expect { try reader.readDocument() } throws: { _ in true }
    }

    @Test func bsonDeprecatedTypesDegrade() throws {
        // undefined (0x06) reads as null; symbol (0x0E) reads as string.
        var raw: [UInt8] = [0, 0, 0, 0]
        raw.append(0x06); raw.append(contentsOf: Array("u".utf8)); raw.append(0)
        raw.append(0x0E); raw.append(contentsOf: Array("s".utf8)); raw.append(0)
        raw.append(contentsOf: [4, 0, 0, 0]); raw.append(contentsOf: Array("sym".utf8)); raw.append(0)
        raw.append(0)
        let length = Int32(raw.count).littleEndian
        withUnsafeBytes(of: length) { raw.replaceSubrange(0..<4, with: $0) }

        var reader = BSONReader(data: Data(raw))
        let pairs = try reader.readDocument()
        #expect(pairs.count == 2)
        #expect(pairs[0].value == .null)
        #expect(pairs[1].value == .string("sym"))
    }
}
