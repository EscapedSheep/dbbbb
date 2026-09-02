import Foundation
import Testing
@testable import dbbbbCore
@testable import dbbbbKit

struct MongoDisplayValueTests {
    @Test func taggedWireShapes() {
        // ObjectId → {"$oid": hex}
        #expect(
            MongoDisplayValue.convert(.objectID(Data(repeating: 0xAB, count: 12)))
                == .object([("$oid", .string("abababababababababababab"))])
        )
        // Int64 → {"$numberLong": string}, never a Double.
        #expect(
            MongoDisplayValue.convert(.int64(9_007_199_254_740_993))
                == .object([("$numberLong", .string("9007199254740993"))])
        )
        // Decimal128 → {"$numberDecimal": string}
        #expect(
            MongoDisplayValue.convert(.decimal128(low: 1, high: 0x303E_0000_0000_0000))
                == .object([("$numberDecimal", .string("0.1"))])
        )
        // Binary → {"$binary": {"base64": …, "subType": …}}
        #expect(
            MongoDisplayValue.convert(.binary(subtype: 0x80, data: Data([1, 2, 3])))
                == .object([("$binary", .object([("base64", .string("AQID")), ("subType", .string("80"))]))])
        )
        // Non-finite doubles cross as tagged strings.
        #expect(MongoDisplayValue.convert(.double(.nan)) == .object([("$numberDouble", .string("NaN"))]))
        #expect(MongoDisplayValue.convert(.double(.infinity)) == .object([("$numberDouble", .string("Infinity"))]))
    }

    @Test func plainShapes() {
        #expect(MongoDisplayValue.convert(.int32(42)) == .number(42))
        #expect(MongoDisplayValue.convert(.double(1.5)) == .number(1.5))
        #expect(MongoDisplayValue.convert(.bool(true)) == .bool(true))
        #expect(MongoDisplayValue.convert(.null) == .null)
        #expect(MongoDisplayValue.convert(.string("hi")) == .string("hi"))
        // Dates cross as `$date`-tagged ISO-8601 strings with milliseconds, so
        // they stay precision-safe and round-trip for editing.
        #expect(
            MongoDisplayValue.convert(.date(milliseconds: 1_700_000_000_000))
                == .object([("$date", .string("2023-11-14T22:13:20.000Z"))])
        )
    }

    @Test func documentOrderPreserved() throws {
        let value = MongoDisplayValue.convert(.document([
            ("b", .int32(1)),
            ("a", .array([.int32(2), .string("x")])),
        ]))
        guard case .object(let pairs) = value else {
            Issue.record("not an object")
            return
        }
        #expect(pairs.map(\.key) == ["b", "a"])
        guard case .array(let items) = pairs[1].value else {
            Issue.record("not an array")
            return
        }
        #expect(items == [.number(2), .string("x")])
    }

    @Test func oversizedStringTruncated() {
        let big = String(repeating: "x", count: 8 * 1024 * 1024 + 100)
        guard case .string(let rendered) = MongoDisplayValue.convert(.string(big)) else {
            Issue.record("not a string")
            return
        }
        #expect(rendered.contains("…[dbbbb truncated 100 bytes]"))
        #expect(rendered.utf8.count < 8 * 1024 * 1024 + 200)
    }
}
