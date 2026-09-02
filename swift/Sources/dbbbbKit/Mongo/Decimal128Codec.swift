import Foundation

/// IEEE 754-2008 decimal128 (BID encoding, as used by BSON) ↔ canonical string.
///
/// The BSON library bundled with MongoKitten ships `Decimal128` as a stub whose
/// bit fields are module-internal, so the adapter implements the conversion
/// itself per the BSON Decimal128 specification: to-string follows the
/// reference algorithm (trailing zeros preserved, scientific notation when the
/// adjusted exponent leaves the regular range), from-string rounds half-even to
/// 34 significant digits, overflows to Infinity, and underflows by shifting.
enum Decimal128Codec {
    static let exponentBias = 6176
    static let maxExponent = 6111
    static let minExponent = -6176
    static let maxSignificandDigits = 34

    static let nanBits: (low: UInt64, high: UInt64) = (0, 0x7C00_0000_0000_0000)
    static let infinityBits: (low: UInt64, high: UInt64) = (0, 0x7800_0000_0000_0000)

    /// 10^34 - 1, the largest canonical significand.
    private static let maxSignificand: UInt128 = {
        var value: UInt128 = 0
        for _ in 0..<maxSignificandDigits { value = value * 10 + 9 }
        return value
    }()

    // MARK: Bits → string

    static func toString(low: UInt64, high: UInt64) -> String {
        let negative = (high >> 63) == 1
        let combination = (high >> 58) & 0x1F

        if combination == 0x1F { return "NaN" }
        if combination == 0x1E { return negative ? "-Infinity" : "Infinity" }

        let biasedExponent: Int
        let significandMsb: UInt64
        if (combination >> 3) == 0b11 {
            biasedExponent = Int((high >> 47) & 0x3FFF)
            significandMsb = 0x08 | ((high >> 46) & 0x01)
        } else {
            biasedExponent = Int((high >> 49) & 0x3FFF)
            significandMsb = (high >> 46) & 0x07
        }
        let exponent = biasedExponent - exponentBias

        var significand = (UInt128(significandMsb) << 110)
            | (UInt128(high & 0x0000_3FFF_FFFF_FFFF) << 64)
            | UInt128(low)
        // Non-canonical significands (≥ 10^34) read as zero per the spec.
        if significand > maxSignificand { significand = 0 }

        let digits = String(significand)
        let significandDigits = digits.count
        let scientificExponent = significandDigits + exponent - 1
        let sign = negative ? "-" : ""

        if scientificExponent >= maxSignificandDigits || scientificExponent <= -7 || exponent > 0 {
            if significand == 0 {
                return "\(sign)0E\(exponent > 0 ? "+" : "")\(exponent)"
            }
            var result = sign + digits.prefix(1)
            if significandDigits > 1 {
                result += "." + digits.dropFirst()
            }
            result += "E"
            result += scientificExponent > 0 ? "+\(scientificExponent)" : "\(scientificExponent)"
            return result
        }

        if exponent == 0 { return sign + digits }

        let radixPosition = significandDigits + exponent
        if radixPosition > 0 {
            let split = digits.index(digits.startIndex, offsetBy: radixPosition)
            return sign + digits[..<split] + "." + digits[split...]
        }
        return sign + "0." + String(repeating: "0", count: -radixPosition) + digits
    }

    // MARK: String → bits

    static func fromString(_ string: String) -> (low: UInt64, high: UInt64)? {
        switch string {
        case "NaN": return nanBits
        case "Infinity", "+Infinity": return infinityBits
        case "-Infinity": return (0, infinityBits.high | 0x8000_0000_0000_0000)
        default: break
        }

        var index = string.startIndex
        let end = string.endIndex

        var negative = false
        if index < end, string[index] == "-" || string[index] == "+" {
            negative = string[index] == "-"
            index = string.index(after: index)
        }

        var integerDigits = ""
        var fractionDigits = ""
        var sawDigit = false
        var sawRadix = false
        while index < end {
            let character = string[index]
            if character >= "0", character <= "9" {
                if sawRadix { fractionDigits.append(character) } else { integerDigits.append(character) }
                sawDigit = true
            } else if character == ".", !sawRadix {
                sawRadix = true
            } else {
                break
            }
            index = string.index(after: index)
        }
        guard sawDigit else { return nil }

        var exponentPart = 0
        if index < end, string[index] == "e" || string[index] == "E" {
            index = string.index(after: index)
            var exponentNegative = false
            if index < end, string[index] == "-" || string[index] == "+" {
                exponentNegative = string[index] == "-"
                index = string.index(after: index)
            }
            var exponentText = ""
            while index < end, string[index] >= "0", string[index] <= "9" {
                exponentText.append(string[index])
                index = string.index(after: index)
            }
            guard !exponentText.isEmpty, let parsed = Int(exponentText), parsed <= 1_000_000 else { return nil }
            exponentPart = exponentNegative ? -parsed : parsed
        }
        guard index == end else { return nil }

        var exponent = exponentPart - fractionDigits.count
        var digits = String((integerDigits + fractionDigits).drop { $0 == "0" })

        if digits.isEmpty {
            // Zero keeps its (clamped) exponent, e.g. "0E+3".
            let clamped = min(max(exponent, minExponent), maxExponent)
            return encode(negative: negative, significand: 0, exponent: clamped)
        }

        if digits.count > maxSignificandDigits {
            // Round half-even to 34 significant digits; the dropped tail moves
            // into the exponent.
            let keepEnd = digits.index(digits.startIndex, offsetBy: maxSignificandDigits)
            let roundDigit = digits[keepEnd]
            let rest = digits[digits.index(after: keepEnd)...]
            var kept = Array(digits[..<keepEnd].utf8)

            let roundUp: Bool
            if roundDigit > "5" {
                roundUp = true
            } else if roundDigit < "5" {
                roundUp = false
            } else if rest.contains(where: { $0 != "0" }) {
                roundUp = true
            } else {
                roundUp = (kept.last! - UInt8(ascii: "0")) % 2 == 1
            }

            if roundUp {
                var position = kept.count - 1
                while true {
                    if kept[position] == UInt8(ascii: "9") {
                        kept[position] = UInt8(ascii: "0")
                        if position == 0 {
                            // 99…9 + 1 overflows: 1 followed by 33 zeros, exponent + 1.
                            kept = [UInt8(ascii: "1")] + Array(repeating: UInt8(ascii: "0"), count: maxSignificandDigits - 1)
                            exponent += 1
                            break
                        }
                        position -= 1
                    } else {
                        kept[position] += 1
                        break
                    }
                }
            }

            exponent += digits.count - maxSignificandDigits
            digits = String(decoding: kept, as: UTF8.self)
        }

        guard var significand = UInt128(digits) else { return nil }

        if exponent > maxExponent {
            // Overflow → signed Infinity (IEEE 754).
            return (0, infinityBits.high | (negative ? 0x8000_0000_0000_0000 : 0))
        }

        while exponent < minExponent, significand > 0 {
            // Underflow: shift right with round half-even.
            let quotient = significand / 10
            let remainder = significand % 10
            significand = quotient
            if remainder > 5 || (remainder == 5 && quotient % 2 == 1) {
                significand += 1
            }
            exponent += 1
        }
        if exponent < minExponent { exponent = minExponent }

        return encode(negative: negative, significand: significand, exponent: exponent)
    }

    private static func encode(negative: Bool, significand: UInt128, exponent: Int) -> (low: UInt64, high: UInt64) {
        var high = UInt64(truncatingIfNeeded: significand >> 64) & 0x0000_3FFF_FFFF_FFFF
        high |= UInt64((significand >> 110) & 0x7) << 46
        high |= UInt64(exponent + exponentBias) << 49
        if negative { high |= 0x8000_0000_0000_0000 }
        return (UInt64(truncatingIfNeeded: significand), high)
    }
}
