import XCTest
import dbbbbCore
import PostgresNIO
@testable import dbbbbKit

final class PostgresWireCodecTests: XCTestCase {
    private func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    private func decode(
        _ oid: PostgresTestOID, _ payload: [UInt8]?, utcOffset: Int = 0
    ) -> DisplayValue {
        PostgresWireCodec.displayValue(
            type: oid.type, bytes: payload, timezoneOffsetSeconds: { _ in utcOffset })
    }

    // MARK: - Scalars

    func testIntegerAndBooleanDecoding() {
        XCTAssertEqual(decode(.bool, [1]), .bool(true))
        XCTAssertEqual(decode(.bool, [0]), .bool(false))
        XCTAssertEqual(decode(.int2, bytes(Int16(-2))), .number(-2))
        XCTAssertEqual(decode(.int4, bytes(Int32(2_147_483_647))), .number(2_147_483_647))
        XCTAssertEqual(decode(.oid, bytes(UInt32(16_388))), .number(16_388))
    }

    func testInt8AlwaysCrossesAsString() {
        XCTAssertEqual(
            decode(.int8, bytes(Int64(9_007_199_254_740_993))),
            .string("9007199254740993"))
        XCTAssertEqual(decode(.int8, bytes(Int64(-42))), .string("-42"))
    }

    func testFloatingPointAndNonFiniteValues() {
        XCTAssertEqual(decode(.float8, bytes(1.5.bitPattern)), .number(1.5))
        XCTAssertEqual(decode(.float8, bytes(Double.infinity.bitPattern)), .string("Infinity"))
        XCTAssertEqual(decode(.float8, bytes((-Double.infinity).bitPattern)), .string("-Infinity"))
        XCTAssertEqual(decode(.float8, bytes(Double.nan.bitPattern)), .string("NaN"))
        XCTAssertEqual(decode(.float4, bytes(Float(0.5).bitPattern)), .number(0.5))
    }

    func testNumericDecodingMatchesServerText() {
        // 12345.678: weight 1, dscale 3, groups [1, 2345, 6780]
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 3, weight: 1, sign: 0, dscale: 3, digits: [1, 2345, 6780])),
            .string("12345.678"))
        // -0.0001
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 1, weight: -1, sign: 0x4000, dscale: 4, digits: [1])),
            .string("-0.0001"))
        // 1.10 keeps its stored display scale
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 2, weight: 0, sign: 0, dscale: 2, digits: [1, 1000])),
            .string("1.10"))
        // 10000 (trailing groups implicit)
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 1, weight: 1, sign: 0, dscale: 0, digits: [1])),
            .string("10000"))
        // 0.5
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 1, weight: -1, sign: 0, dscale: 1, digits: [5000])),
            .string("0.5"))
        // 0.00001 (group 1000 at weight -2: 1000 × 10000⁻² = 10⁻⁵)
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 1, weight: -2, sign: 0, dscale: 5, digits: [1000])),
            .string("0.00001"))
        // zero
        XCTAssertEqual(
            decode(.numeric, numeric(ndigits: 0, weight: 0, sign: 0, dscale: 0, digits: [])),
            .string("0"))
        // specials
        XCTAssertEqual(decode(.numeric, numeric(ndigits: 0, weight: 0, sign: 0xC000, dscale: 0, digits: [])), .string("NaN"))
        XCTAssertEqual(decode(.numeric, numeric(ndigits: 0, weight: 0, sign: 0xD000, dscale: 0, digits: [])), .string("Infinity"))
        XCTAssertEqual(decode(.numeric, numeric(ndigits: 0, weight: 0, sign: 0xF000, dscale: 0, digits: [])), .string("-Infinity"))
    }

    private func numeric(ndigits: Int16, weight: Int16, sign: UInt16, dscale: Int16, digits: [Int16]) -> [UInt8] {
        var payload = bytes(ndigits) + bytes(weight) + bytes(sign) + bytes(dscale)
        for digit in digits { payload += bytes(digit) }
        return payload
    }

    func testByteaJsonUuidAndFallbacks() {
        XCTAssertEqual(decode(.bytea, [0xDE, 0xAD]), .binary(Data([0xDE, 0xAD])))
        XCTAssertEqual(decode(.jsonb, [1] + Array(#"{"a":1}"#.utf8)), .string(#"{"a":1}"#))
        XCTAssertEqual(
            decode(.uuid, [UInt8](arrayLiteral:
                0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)),
            .string("00112233-4455-6677-8899-aabbccddeeff"))
        // Unknown OIDs fall back to UTF-8 text, like PostgresNIO's String decoder.
        XCTAssertEqual(decode(.unknown(19_999), Array("hstore-ish".utf8)), .string("hstore-ish"))
        XCTAssertEqual(decode(.text, nil), .null)
    }

    // MARK: - Temporal

    func testCivilCalendarMath() {
        XCTAssertTrue(PostgresWireCodec.civilFromDays(0) == (1970, 1, 1))
        XCTAssertTrue(PostgresWireCodec.civilFromDays(10_957) == (2000, 1, 1))
        XCTAssertTrue(PostgresWireCodec.civilFromDays(-719_162) == (1, 1, 1))
        XCTAssertTrue(PostgresWireCodec.civilFromDays(-719_163) == (0, 12, 31))
        XCTAssertTrue(PostgresWireCodec.civilFromDays(-1) == (1969, 12, 31))
    }

    func testDateRendering() {
        XCTAssertEqual(PostgresWireCodec.renderDate(days: 0), "2000-01-01")
        XCTAssertEqual(PostgresWireCodec.renderDate(days: -1), "1999-12-31")
        XCTAssertEqual(PostgresWireCodec.renderDate(days: Int32.max), "infinity")
        XCTAssertEqual(PostgresWireCodec.renderDate(days: Int32.min), "-infinity")
        // Day 0 of the proleptic calendar boundary: 0001-12-31 BC.
        XCTAssertEqual(PostgresWireCodec.renderDate(days: Int32(-719_162 - 10_957 - 1)), "0001-12-31 BC")
        XCTAssertEqual(decode(.date, bytes(Int32(8_000))), .string("2021-11-26"))
    }

    func testTimestampRendering() {
        XCTAssertEqual(PostgresWireCodec.renderTimestamp(microseconds: 0, suffix: ""), "2000-01-01 00:00:00")
        XCTAssertEqual(
            PostgresWireCodec.renderTimestamp(microseconds: 3_723_456_789, suffix: ""),
            "2000-01-01 01:02:03.456789")
        XCTAssertEqual(
            PostgresWireCodec.renderTimestamp(microseconds: -1, suffix: ""),
            "1999-12-31 23:59:59.999999")
        XCTAssertEqual(PostgresWireCodec.renderTimestamp(microseconds: Int64.max, suffix: ""), "infinity")
        XCTAssertEqual(PostgresWireCodec.renderTimestamp(microseconds: Int64.min, suffix: ""), "-infinity")
        // Trailing fractional zeros are trimmed like the server does.
        XCTAssertEqual(
            PostgresWireCodec.renderTimestamp(microseconds: 1_500_000, suffix: ""),
            "2000-01-01 00:00:01.5")
    }

    func testTimestamptzRenderingUsesSessionOffset() {
        XCTAssertEqual(decode(.timestamptz, bytes(Int64(0)), utcOffset: 28_800), .string("2000-01-01 08:00:00+08"))
        XCTAssertEqual(decode(.timestamptz, bytes(Int64(0)), utcOffset: -18_000), .string("1999-12-31 19:00:00-05"))
        XCTAssertEqual(decode(.timestamptz, bytes(Int64(0)), utcOffset: 19_800), .string("2000-01-01 05:30:00+05:30"))
        XCTAssertEqual(decode(.timestamptz, bytes(Int64.max)), .string("infinity"))
    }

    func testTimeAndTimetzRendering() {
        XCTAssertEqual(PostgresWireCodec.renderTimeOfDay(microseconds: 0), "00:00:00")
        XCTAssertEqual(PostgresWireCodec.renderTimeOfDay(microseconds: 3_723_456_789), "01:02:03.456789")
        // timetz stores the zone as seconds *west* of UTC.
        let payload = bytes(Int64(3_600_000_000)) + bytes(Int32(-28_800))
        XCTAssertEqual(decode(.timetz, payload), .string("01:00:00+08"))
    }

    func testZoneOffsetSuffixes() {
        XCTAssertEqual(PostgresWireCodec.renderZoneOffset(28_800), "+08")
        XCTAssertEqual(PostgresWireCodec.renderZoneOffset(-18_000), "-05")
        XCTAssertEqual(PostgresWireCodec.renderZoneOffset(19_800), "+05:30")
        XCTAssertEqual(PostgresWireCodec.renderZoneOffset(3_208), "+00:53:28")
        XCTAssertEqual(PostgresWireCodec.renderZoneOffset(0), "+00")
    }

    func testIntervalRendering() {
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 0, days: 1, months: 14),
            "1 year 2 mons 1 day")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 0, days: 2, months: -12),
            "-1 years +2 days")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 0, days: 0, months: -1),
            "-1 mons")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: -7_200_000_000, days: 1, months: 0),
            "1 day -02:00:00")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 7_200_000_000, days: -1, months: 0),
            "-1 days +02:00:00")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 0, days: 0, months: 0),
            "00:00:00")
        XCTAssertEqual(
            PostgresWireCodec.renderInterval(microseconds: 3_723_456_789, days: 0, months: 1),
            "1 mon 01:02:03.456789")
    }

    // MARK: - Network types

    func testInetAndCidrRendering() {
        XCTAssertEqual(decode(.inet, [2, 32, 0, 4, 10, 0, 0, 1]), .string("10.0.0.1/32"))
        XCTAssertEqual(decode(.cidr, [2, 32, 1, 4, 10, 0, 0, 1]), .string("10.0.0.1"))
        XCTAssertEqual(decode(.cidr, [2, 8, 1, 4, 10, 0, 0, 0]), .string("10.0.0.0/8"))
        XCTAssertEqual(
            decode(.inet, [3, 128, 0, 16,
                           0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]),
            .string("2001:db8::1/128"))
        XCTAssertEqual(decode(.macaddr, [0x08, 0x00, 0x2b, 0x01, 0x02, 0x03]), .string("08:00:2b:01:02:03"))
    }

    // MARK: - Arrays

    func testArrayDecoding() {
        // int4[] {1, NULL, 3}
        var payload = bytes(Int32(1)) + bytes(Int32(1)) + bytes(Int32(23))
        payload += bytes(Int32(3)) + bytes(Int32(1)) // dim 3, lbound 1
        payload += bytes(Int32(4)) + bytes(Int32(1))
        payload += bytes(Int32(-1))
        payload += bytes(Int32(4)) + bytes(Int32(3))
        XCTAssertEqual(
            decode(.int4Array, payload),
            .array([.number(1), .null, .number(3)]))

        // text[][] {{a,b},{c,d}}
        var matrix = bytes(Int32(2)) + bytes(Int32(0)) + bytes(Int32(25))
        matrix += bytes(Int32(2)) + bytes(Int32(1))
        matrix += bytes(Int32(2)) + bytes(Int32(1))
        for element in ["a", "b", "c", "d"] {
            let utf8 = Array(element.utf8)
            matrix += bytes(Int32(utf8.count)) + utf8
        }
        XCTAssertEqual(
            decode(.textArray, matrix),
            .array([.array([.string("a"), .string("b")]), .array([.string("c"), .string("d")])]))

        // Empty array.
        let empty = bytes(Int32(0)) + bytes(Int32(0)) + bytes(Int32(25))
        XCTAssertEqual(decode(.textArray, empty), .array([]))
    }

    // MARK: - Bounding

    func testOversizedSingleValuesGetVisibleTruncationMarker() {
        let oversized = String(repeating: "x", count: PostgresWireCodec.maxValueBytes + 1024 * 1024)
        let bounded = PostgresWireCodec.boundedString(oversized)
        XCTAssertLessThan(bounded.count, oversized.count)
        XCTAssertTrue(bounded.hasPrefix(String(repeating: "x", count: 1024)))
        XCTAssertTrue(bounded.contains("[dbbbb truncated 1048576 bytes]"))

        let binary = PostgresWireCodec.boundedBinary(
            Data(repeating: 0xAB, count: PostgresWireCodec.maxValueBytes + 1024 * 1024))
        guard case .binary(let data) = binary else { return XCTFail("expected binary") }
        XCTAssertTrue(data.count > PostgresWireCodec.maxValueBytes)
        XCTAssertTrue(String(decoding: data.suffix(64), as: UTF8.self)
            .contains("[dbbbb truncated 1048576 bytes]"))
    }

    func testTruncationMarkerCountsOmittedBytes() {
        XCTAssertEqual(PostgresWireCodec.truncatedMarker(omittedBytes: 7), "…[dbbbb truncated 7 bytes]")
    }

    func testBoundRowsUsesMaxRowsAndByteBudget() {
        let threeRows: [[DisplayValue]] = [[.number(1)], [.number(2)], [.number(3)]]
        let bounded = PostgresWireCodec.boundRows(threeRows, maxRows: 2, maxBytes: 10_000)
        XCTAssertEqual(bounded.rows, [[.number(1)], [.number(2)]])
        XCTAssertTrue(bounded.truncated)

        let firstRowBytes = PostgresWireCodec.jsonByteCount(of: [.string("ok")])
        let budgeted = PostgresWireCodec.boundRows(
            [[.string("ok")], [.string("too large")]], maxRows: 2, maxBytes: firstRowBytes)
        XCTAssertEqual(budgeted.rows, [[.string("ok")]])
        XCTAssertTrue(budgeted.truncated)

        let exact = PostgresWireCodec.boundRows([[.string("ok")]], maxRows: 5, maxBytes: 10_000)
        XCTAssertFalse(exact.truncated)
    }

    func testColumnMetaDeduplicatesNames() {
        let metas = PostgresWireCodec.columnMetas([
            ("id", .int4), ("id", .int8), ("note", .text),
        ])
        XCTAssertEqual(metas.map(\.name), ["id", "id:1", "note"])
        XCTAssertEqual(metas[0].typeName, "int4")
        XCTAssertTrue(metas[0].numeric)
        XCTAssertFalse(metas[2].numeric)
        XCTAssertEqual(metas[2].typeName, "text")
    }
}

/// Test-side OID vocabulary so tests do not need PostgresNIO internals.
enum PostgresTestOID {
    case bool, int2, int4, int8, oid, float4, float8, numeric, bytea, jsonb, uuid
    case date, timestamptz, timetz, inet, cidr, macaddr, int4Array, textArray, text
    case unknown(UInt32)

    var type: PostgresDataType {
        switch self {
        case .bool: .init(16)
        case .int2: .init(21)
        case .int4: .init(23)
        case .int8: .init(20)
        case .oid: .init(26)
        case .float4: .init(700)
        case .float8: .init(701)
        case .numeric: .init(1700)
        case .bytea: .init(17)
        case .jsonb: .init(3802)
        case .uuid: .init(2950)
        case .date: .init(1082)
        case .timestamptz: .init(1184)
        case .timetz: .init(1266)
        case .inet: .init(869)
        case .cidr: .init(650)
        case .macaddr: .init(829)
        case .int4Array: .init(1007)
        case .textArray: .init(1009)
        case .text: .init(25)
        case .unknown(let raw): .init(raw)
        }
    }
}
