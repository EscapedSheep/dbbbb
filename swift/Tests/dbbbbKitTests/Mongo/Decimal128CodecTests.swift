import Testing
@testable import dbbbbKit

struct Decimal128CodecTests {
    // MARK: Known bit vectors (verified arithmetically against the BID layout)

    @Test func specialValues() {
        #expect(Decimal128Codec.toString(low: 0, high: 0x7C00_0000_0000_0000) == "NaN")
        #expect(Decimal128Codec.toString(low: 0, high: 0x7800_0000_0000_0000) == "Infinity")
        #expect(Decimal128Codec.toString(low: 0, high: 0xF800_0000_0000_0000) == "-Infinity")

        #expect(Decimal128Codec.fromString("NaN")?.high == 0x7C00_0000_0000_0000)
        #expect(Decimal128Codec.fromString("Infinity")?.high == 0x7800_0000_0000_0000)
        #expect(Decimal128Codec.fromString("-Infinity")?.high == 0xF800_0000_0000_0000)
    }

    @Test func integerOneBits() {
        // biased exponent 6176 (0x1820) in bits 49...62, significand 1.
        let bits = Decimal128Codec.fromString("1")
        #expect(bits?.high == 0x3040_0000_0000_0000)
        #expect(bits?.low == 1)
        #expect(Decimal128Codec.toString(low: 1, high: 0x3040_0000_0000_0000) == "1")
    }

    @Test func zeroBits() {
        let bits = Decimal128Codec.fromString("0")
        #expect(bits?.high == 0x3040_0000_0000_0000)
        #expect(bits?.low == 0)
        #expect(Decimal128Codec.toString(low: 0, high: 0x3040_0000_0000_0000) == "0")
    }

    @Test func negativeOneBits() {
        let bits = Decimal128Codec.fromString("-1")
        #expect(bits?.high == 0xB040_0000_0000_0000)
        #expect(bits?.low == 1)
        #expect(Decimal128Codec.toString(low: 1, high: 0xB040_0000_0000_0000) == "-1")
    }

    @Test func oneTenthBits() {
        // significand 1, exponent -1 → biased 6175 (0x181F).
        let bits = Decimal128Codec.fromString("0.1")
        #expect(bits?.high == 0x303E_0000_0000_0000)
        #expect(bits?.low == 1)
        #expect(Decimal128Codec.toString(low: 1, high: 0x303E_0000_0000_0000) == "0.1")
    }

    @Test func largeIntegerBits() {
        // 20-digit significand that still fits in the low word, exponent 0.
        let bits = Decimal128Codec.fromString("12345678901234567890")
        #expect(bits?.high == 0x3040_0000_0000_0000)
        #expect(bits?.low == 12_345_678_901_234_567_890)
    }

    @Test func allZeroBitsDecode() {
        // exponent field 0 → biased 0 → exponent -6176, significand 0.
        #expect(Decimal128Codec.toString(low: 0, high: 0) == "0E-6176")
    }

    // MARK: Round-trips through canonical strings

    @Test(arguments: [
        "0", "-0", "1", "-1", "10", "0.1", "0.10", "1.000", "0.001234",
        "1234567890123456789012345678901234",       // 34 digits
        "9999999999999999999999999999999999",       // 34 nines
        "0.000001", "1E+3", "-1.5E+3", "1.234E-7", "9.999999999999999999999999999999999E+6111",
        "1E-6176", "0E+3", "1.000000000000000000000000000000000",
        "3.141592653589793238462643383279",
    ])
    func canonicalStringRoundTrip(string: String) throws {
        let bits = try #require(Decimal128Codec.fromString(string), "fromString rejected \(string)")
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == string)
    }

    // MARK: Rounding and range behavior

    @Test func roundHalfEvenDown() throws {
        // 35 significant digits, dropped digit 5 with even predecessor.
        let bits = try #require(Decimal128Codec.fromString("1.0000000000000000000000000000000005"))
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == "1.000000000000000000000000000000000")
    }

    @Test func roundHalfEvenUp() throws {
        // dropped digit 5 with odd predecessor rounds up.
        let bits = try #require(Decimal128Codec.fromString("1.0000000000000000000000000000000015"))
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == "1.000000000000000000000000000000002")
    }

    @Test func roundUpCarryOverflow() throws {
        // 34 nines rounded up spills into 1 followed by zeros with exponent + 1.
        let bits = try #require(Decimal128Codec.fromString("9.9999999999999999999999999999999995"))
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == "10.00000000000000000000000000000000")
    }

    @Test func exponentOverflowBecomesInfinity() {
        #expect(Decimal128Codec.fromString("1E+6112")?.high == 0x7800_0000_0000_0000)
        #expect(Decimal128Codec.fromString("-1E+6112")?.high == 0xF800_0000_0000_0000)
    }

    @Test func underflowShiftsToZero() throws {
        let bits = try #require(Decimal128Codec.fromString("1E-6177"))
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == "0E-6176")
    }

    @Test func zeroKeepsClampedExponent() throws {
        let bits = try #require(Decimal128Codec.fromString("0E+7000"))
        #expect(Decimal128Codec.toString(low: bits.low, high: bits.high) == "0E+6111")
    }

    @Test func nonCanonicalSignificandReadsAsZero() {
        // combination 0b11000 → implied significand msb 8 → ≥ 10^34 → zero.
        let high: UInt64 = 0b11000 << 58
        #expect(Decimal128Codec.toString(low: 0, high: high) == "0E-6176")
    }

    @Test(arguments: ["", "abc", "1.2.3", "1e", "e5", "--1", "1 ", " 1", "0x10", "NaNa", "1E+1000001"])
    func invalidStringsRejected(string: String) {
        #expect(Decimal128Codec.fromString(string) == nil)
    }
}
