import Foundation
import dbbbbCore
import PostgresNIO

/// Pure wire-value layer for the PostgreSQL adapter.
///
/// PostgresNIO always requests **binary** result format, so — unlike the
/// Electron adapter, which kept the driver's raw text for temporal types —
/// this codec reconstructs the server's canonical *text* rendering from the
/// binary representation for precision-sensitive types (temporal, numeric,
/// money, int8). Precision-sensitive values therefore still cross as strings,
/// and temporal values remain lossless display text (the `setTypeParser`
/// equivalent).
enum PostgresWireCodec {
    /// A single oversized value is truncated above this size and marked, so it
    /// is visibly incomplete.
    static let maxValueBytes = 8 * 1024 * 1024

    static func truncatedMarker(omittedBytes: Int) -> String {
        "…[dbbbb truncated \(omittedBytes) bytes]"
    }

    static func boundedString(_ text: String) -> String {
        let bytes = text.utf8.count
        guard bytes > maxValueBytes else { return text }
        // Cutting at a byte boundary may split a multi-byte scalar; decoding
        // repairs the tail with a replacement character, same as the Electron
        // adapter's Buffer#toString behavior.
        let kept = String(decoding: text.utf8.prefix(maxValueBytes), as: UTF8.self)
        return kept + truncatedMarker(omittedBytes: bytes - maxValueBytes)
    }

    static func boundedBinary(_ data: Data) -> DisplayValue {
        guard data.count > maxValueBytes else { return .binary(data) }
        var kept = data.prefix(maxValueBytes)
        kept.append(contentsOf: truncatedMarker(omittedBytes: data.count - maxValueBytes).utf8)
        return .binary(Data(kept))
    }

    // MARK: - Cell decoding

    /// Maps one binary-format cell to a display value. `timezoneOffsetSeconds`
    /// resolves the session-timezone UTC offset (in seconds, positive east)
    /// for a given instant expressed as microseconds since 2000-01-01 UTC.
    static func displayValue(
        type: PostgresDataType,
        bytes: [UInt8]?,
        timezoneOffsetSeconds: (Int64) -> Int
    ) -> DisplayValue {
        guard let bytes else { return .null }

        switch type {
        case .bool:
            guard let byte = bytes.first, bytes.count == 1 else { return fallbackText(bytes) }
            return .bool(byte != 0)

        case .int2:
            guard let value = readInt(bytes, as: Int16.self) else { return fallbackText(bytes) }
            return .number(Double(value))

        case .int4:
            guard let value = readInt(bytes, as: Int32.self) else { return fallbackText(bytes) }
            return .number(Double(value))

        case .int8:
            // Always a string: Int64 does not survive Double losslessly.
            guard let value = readInt(bytes, as: Int64.self) else { return fallbackText(bytes) }
            return .string(String(value))

        case .oid:
            guard let value = readInt(bytes, as: UInt32.self) else { return fallbackText(bytes) }
            return .number(Double(value))

        case .float4:
            guard let bits = readInt(bytes, as: UInt32.self) else { return fallbackText(bytes) }
            return floatingDisplayValue(Double(Float32(bitPattern: bits)))

        case .float8:
            guard let bits = readInt(bytes, as: UInt64.self) else { return fallbackText(bytes) }
            return floatingDisplayValue(Double(bitPattern: bits))

        case .numeric:
            guard let text = decodeNumeric(bytes) else { return fallbackText(bytes) }
            return .string(text)

        case .money:
            // Binary money is an Int64 of fractional cents; the server's text
            // rendering is locale-dependent, so render a stable scaled decimal.
            guard let cents = readInt(bytes, as: Int64.self) else { return fallbackText(bytes) }
            return .string(renderMoney(cents))

        case .bytea:
            return boundedBinary(Data(bytes))

        case .jsonb:
            // Binary jsonb is a version byte followed by UTF-8 text.
            guard bytes.first == 1 else { return fallbackText(bytes) }
            return .string(boundedString(String(decoding: bytes.dropFirst(), as: UTF8.self)))

        case .uuid:
            guard bytes.count == 16 else { return fallbackText(bytes) }
            return .string(renderUUID(bytes))

        case .date:
            guard let days = readInt(bytes, as: Int32.self) else { return fallbackText(bytes) }
            return .string(renderDate(days: days))

        case .timestamp:
            guard let micros = readInt(bytes, as: Int64.self) else { return fallbackText(bytes) }
            return .string(renderTimestamp(microseconds: micros, suffix: ""))

        case .timestamptz:
            guard let micros = readInt(bytes, as: Int64.self) else { return fallbackText(bytes) }
            if micros == Int64.max { return .string("infinity") }
            if micros == Int64.min { return .string("-infinity") }
            let offset = timezoneOffsetSeconds(micros)
            return .string(renderTimestamp(
                microseconds: micros &+ Int64(offset) &* 1_000_000,
                suffix: renderZoneOffset(offset)))

        case .time:
            guard let micros = readInt(bytes, as: Int64.self) else { return fallbackText(bytes) }
            return .string(renderTimeOfDay(microseconds: micros))

        case .timetz:
            guard bytes.count == 12,
                  let micros = readInt(bytes.prefix(8), as: Int64.self),
                  let zone = readInt(bytes.suffix(4), as: Int32.self)
            else { return fallbackText(bytes) }
            // Binary timetz stores seconds *west* of UTC.
            return .string(renderTimeOfDay(microseconds: micros) + renderZoneOffset(-Int(zone)))

        case .interval:
            guard bytes.count == 16,
                  let micros = readInt(bytes.prefix(8), as: Int64.self),
                  let days = readInt(bytes.dropFirst(8).prefix(4), as: Int32.self),
                  let months = readInt(bytes.suffix(4), as: Int32.self)
            else { return fallbackText(bytes) }
            return .string(renderInterval(microseconds: micros, days: days, months: months))

        case .inet, .cidr:
            guard let text = renderInet(bytes) else { return fallbackText(bytes) }
            return .string(text)

        case .macaddr:
            guard bytes.count == 6 else { return fallbackText(bytes) }
            return .string(bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))

        case .macaddr8:
            guard bytes.count == 8 else { return fallbackText(bytes) }
            return .string(bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))

        default:
            if let array = decodeArray(bytes: bytes, timezoneOffsetSeconds: timezoneOffsetSeconds) {
                return array
            }
            return fallbackText(bytes)
        }
    }

    /// PostgresNIO's own String decoder precedent: for anything unrecognized,
    /// read the payload as UTF-8 text. Enum labels and most string-ish
    /// extension types use their text bytes in binary mode too.
    private static func fallbackText(_ bytes: [UInt8]) -> DisplayValue {
        .string(boundedString(String(decoding: bytes, as: UTF8.self)))
    }

    private static func floatingDisplayValue(_ value: Double) -> DisplayValue {
        if value.isNaN { return .string("NaN") }
        if value == .infinity { return .string("Infinity") }
        if value == -.infinity { return .string("-Infinity") }
        return .number(value)
    }

    // MARK: - Binary readers

    static func readInt<T: FixedWidthInteger>(
        _ bytes: some Collection<UInt8>, as type: T.Type
    ) -> T? {
        guard bytes.count == MemoryLayout<T>.size else { return nil }
        var unsigned: T.Magnitude = 0
        for byte in bytes { unsigned = (unsigned << 8) | T.Magnitude(byte) }
        // Same-size bit reinterpretation (big-endian two's complement on the wire).
        return unsafeBitCast(unsigned, to: T.self)
    }

    // MARK: - numeric

    /// Decodes the binary `numeric` format (base-10000 digits) into the exact
    /// text the server would print, including its stored display scale.
    static func decodeNumeric(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 8 else { return nil }
        guard let ndigitsRaw = readInt(bytes.prefix(2), as: Int16.self),
              let weight = readInt(bytes.dropFirst(2).prefix(2), as: Int16.self),
              let sign = readInt(bytes.dropFirst(4).prefix(2), as: UInt16.self),
              let dscale = readInt(bytes.dropFirst(6).prefix(2), as: Int16.self)
        else { return nil }

        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        case 0x0000, 0x4000: break
        default: return nil
        }
        let negative = sign == 0x4000
        let ndigits = Int(ndigitsRaw)
        guard ndigits >= 0, dscale >= 0, bytes.count == 8 + ndigits * 2 else { return nil }

        var digits: [Int] = []
        digits.reserveCapacity(ndigits)
        for index in 0..<ndigits {
            guard let digit = readInt(bytes.dropFirst(8 + index * 2).prefix(2), as: Int16.self),
                  digit >= 0, digit < 10_000 else { return nil }
            digits.append(Int(digit))
        }

        let firstGroupWeight = Int(weight)
        var text = negative ? "-" : ""

        if firstGroupWeight < 0 {
            text += "0"
        } else {
            for groupIndex in 0...firstGroupWeight {
                let group = groupIndex < digits.count ? digits[groupIndex] : 0
                text += groupIndex == 0 ? String(group) : String(format: "%04d", group)
            }
        }

        if dscale > 0 {
            text += "."
            var fraction = ""
            var groupIndex = firstGroupWeight + 1
            while fraction.count < Int(dscale) {
                let group = groupIndex >= 0 && groupIndex < digits.count ? digits[groupIndex] : 0
                fraction += String(format: "%04d", group)
                groupIndex += 1
            }
            text += fraction.prefix(Int(dscale))
        }

        return text
    }

    // MARK: - money / uuid / inet

    static func renderMoney(_ cents: Int64) -> String {
        let negative = cents < 0
        let magnitude = cents.magnitude
        return "\(negative ? "-" : "")\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }

    static func renderUUID(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        var result = ""
        for (index, character) in hex.enumerated() {
            if [8, 12, 16, 20].contains(index) { result.append("-") }
            result.append(character)
        }
        return result
    }

    /// Binary inet/cidr: address family byte (2 = IPv4, 3 = IPv6), prefix bits,
    /// is_cidr flag, address byte count, then the address bytes.
    static func renderInet(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let family = bytes[0]
        let bits = bytes[1]
        let isCIDR = bytes[2] != 0
        let addressLength = Int(bytes[3])
        guard bytes.count == 4 + addressLength else { return nil }
        let address = bytes.dropFirst(4)

        let addressText: String
        let fullBits: UInt8
        switch family {
        case 2: // AF_INET
            guard addressLength == 4 else { return nil }
            addressText = address.map(String.init).joined(separator: ".")
            fullBits = 32
        case 3: // AF_INET6
            guard addressLength == 16 else { return nil }
            var groups: [String] = []
            for index in stride(from: 0, to: 16, by: 2) {
                let value = (UInt16(address[address.index(address.startIndex, offsetBy: index)]) << 8)
                    | UInt16(address[address.index(address.startIndex, offsetBy: index + 1)])
                groups.append(String(value, radix: 16))
            }
            addressText = compressIPv6Groups(groups)
            fullBits = 128
        default:
            return nil
        }

        // The server always shows the prefix for inet, and suppresses the
        // default (full) prefix for cidr.
        if !isCIDR || bits != fullBits {
            return "\(addressText)/\(bits)"
        }
        return addressText
    }

    /// RFC 5952-ish compression of the longest run of zero groups.
    static func compressIPv6Groups(_ groups: [String]) -> String {
        var bestStart = -1, bestLength = 0, currentStart = -1, currentLength = 0
        for (index, group) in groups.enumerated() {
            if UInt16(group, radix: 16) == 0 {
                if currentStart == -1 { currentStart = index; currentLength = 0 }
                currentLength += 1
                if currentLength > bestLength { bestStart = currentStart; bestLength = currentLength }
            } else {
                currentStart = -1
            }
        }
        guard bestLength >= 2 else { return groups.joined(separator: ":") }
        let head = groups[..<bestStart].joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].joined(separator: ":")
        return "\(head)::\(tail)"
    }

    // MARK: - temporal rendering

    /// Days between 1970-01-01 and the PostgreSQL epoch 2000-01-01.
    private static let postgresEpochDayOffset: Int64 = 10_957
    private static let microsecondsPerDay: Int64 = 86_400_000_000

    static func renderDate(days: Int32) -> String {
        if days == Int32.max { return "infinity" }
        if days == Int32.min { return "-infinity" }
        let civil = civilFromDays(Int64(days) + postgresEpochDayOffset)
        return formatDate(civil)
    }

    /// Renders a `timestamp`/`timestamptz` microsecond count (since
    /// 2000-01-01, in the target zone) as the server would print it.
    static func renderTimestamp(microseconds: Int64, suffix: String) -> String {
        if microseconds == Int64.max { return "infinity" }
        if microseconds == Int64.min { return "-infinity" }
        let days = microseconds.divideFloor(by: microsecondsPerDay)
        let remainder = microseconds - days * microsecondsPerDay
        let civil = civilFromDays(days + postgresEpochDayOffset)
        return "\(formatDate(civil)) \(renderTimeOfDay(microseconds: remainder))\(suffix)"
    }

    static func renderTimeOfDay(microseconds: Int64) -> String {
        var remaining = microseconds
        let hours = remaining / 3_600_000_000
        remaining %= 3_600_000_000
        let minutes = remaining / 60_000_000
        remaining %= 60_000_000
        let seconds = remaining / 1_000_000
        let fraction = remaining % 1_000_000
        var text = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        if fraction != 0 {
            var digits = String(format: "%06d", fraction)
            while digits.hasSuffix("0") { digits.removeLast() }
            text += ".\(digits)"
        }
        return text
    }

    /// Server-style zone suffix: `+HH`, `+HH:MM`, or `+HH:MM:SS` (negative
    /// west of UTC).
    static func renderZoneOffset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3600
        let minutes = (magnitude % 3600) / 60
        let secs = magnitude % 60
        if secs != 0 {
            return String(format: "%@%02d:%02d:%02d", sign, hours, minutes, secs)
        }
        if minutes != 0 {
            return String(format: "%@%02d:%02d", sign, hours, minutes)
        }
        return String(format: "%@%02d", sign, hours)
    }

    /// Howard Hinnant's civil-from-days algorithm; `z` counts days since
    /// 1970-01-01 and may be negative (proleptic Gregorian calendar).
    static func civilFromDays(_ z0: Int64) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = z >= 0 ? z / 146_097 : (z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (Int(year + (month <= 2 ? 1 : 0)), Int(month), Int(day))
    }

    private static func formatDate(_ civil: (year: Int, month: Int, day: Int)) -> String {
        if civil.year <= 0 {
            // Astronomical year 0 is 1 BC, -1 is 2 BC, and so on.
            return String(format: "%04d-%02d-%02d BC", 1 - civil.year, civil.month, civil.day)
        }
        return String(format: "%04d-%02d-%02d", civil.year, civil.month, civil.day)
    }

    /// Renders binary `interval` (microseconds, days, months) in the server's
    /// default `postgres` IntervalStyle: each field keeps its own sign, and a
    /// positive field following a negative one gets an explicit `+`.
    static func renderInterval(microseconds: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        var isBefore = false

        func append(_ value: Int, singular: String, plural: String) {
            guard value != 0 else { return }
            let prefix = value < 0 ? "" : (isBefore ? "+" : "")
            // The server pluralizes every value except exactly 1 ("-1 years").
            parts.append("\(prefix)\(value) \(value == 1 ? singular : plural)")
            if value < 0 { isBefore = true }
        }

        append(Int(months) / 12, singular: "year", plural: "years")
        append(Int(months) % 12, singular: "mon", plural: "mons")
        append(Int(days), singular: "day", plural: "days")

        var time = ""
        if microseconds != 0 {
            let negative = microseconds < 0
            var remaining = Int64(clamping: microseconds.magnitude)
            let hours = remaining / 3_600_000_000
            remaining %= 3_600_000_000
            let minutes = remaining / 60_000_000
            remaining %= 60_000_000
            let seconds = remaining / 1_000_000
            let fraction = remaining % 1_000_000
            let sign = negative ? "-" : (isBefore ? "+" : "")
            time = String(format: "%@%02d:%02d:%02d", sign, hours, minutes, seconds)
            if fraction != 0 {
                var digits = String(format: "%06d", fraction)
                while digits.hasSuffix("0") { digits.removeLast() }
                time += ".\(digits)"
            }
        }
        if !time.isEmpty { parts.append(time) }
        return parts.isEmpty ? "00:00:00" : parts.joined(separator: " ")
    }

    // MARK: - arrays

    /// Decodes the binary array format when the element type is one we can
    /// decode; returns nil for unknown element types or malformed payloads.
    private static func decodeArray(
        bytes: [UInt8],
        timezoneOffsetSeconds: (Int64) -> Int
    ) -> DisplayValue? {
        guard bytes.count >= 12,
              let ndims = readInt(bytes.prefix(4), as: Int32.self),
              let elementTypeFromHeader = readInt(bytes.dropFirst(8).prefix(4), as: Int32.self)
        else { return nil }
        guard ndims >= 0, ndims <= 6 else { return nil }
        // The header always carries the *element* type; decode elements with
        // it (the cell's own OID is the array type).
        let elementType = PostgresDataType(UInt32(bitPattern: elementTypeFromHeader))

        var offset = 12
        var dimensions: [Int] = []
        var total = 1
        for _ in 0..<Int(ndims) {
            guard bytes.count >= offset + 8,
                  let dim = readInt(bytes.dropFirst(offset).prefix(4), as: Int32.self)
            else { return nil }
            offset += 8 // skip lower bound
            guard dim >= 0, dim <= 1_000_000 else { return nil }
            dimensions.append(Int(dim))
            total *= Int(dim)
            guard total <= 1_000_000 else { return nil }
        }
        if ndims == 0 { return .array([]) }

        var flat: [DisplayValue] = []
        flat.reserveCapacity(total)
        for _ in 0..<total {
            guard bytes.count >= offset + 4,
                  let length = readInt(bytes.dropFirst(offset).prefix(4), as: Int32.self)
            else { return nil }
            offset += 4
            if length == -1 {
                flat.append(.null)
                continue
            }
            guard length >= 0, bytes.count >= offset + Int(length) else { return nil }
            let elementBytes = Array(bytes[offset..<(offset + Int(length))])
            offset += Int(length)
            let value = displayValue(
                type: elementType, bytes: elementBytes, timezoneOffsetSeconds: timezoneOffsetSeconds)
            flat.append(value)
        }
        guard offset == bytes.count else { return nil }

        func nest(_ values: ArraySlice<DisplayValue>, dims: ArraySlice<Int>) -> DisplayValue {
            guard let dim = dims.first else { return values.first ?? .null }
            let strideLength = dims.dropFirst().reduce(1, *)
            var children: [DisplayValue] = []
            children.reserveCapacity(dim)
            var rest = values
            for _ in 0..<dim {
                children.append(nest(rest.prefix(strideLength), dims: dims.dropFirst()))
                rest = rest.dropFirst(strideLength)
            }
            return .array(children)
        }

        return nest(flat[...], dims: dimensions[...])
    }

    // MARK: - row bounding

    /// Applies the row and byte budgets to fully collected rows. The byte
    /// budget uses the JSON wire size of each row, like the Electron adapter.
    static func boundRows(
        _ rawRows: [[DisplayValue]],
        maxRows: Int,
        maxBytes: Int
    ) -> (rows: [[DisplayValue]], truncated: Bool) {
        var rows: [[DisplayValue]] = []
        rows.reserveCapacity(min(rawRows.count, maxRows))
        var bytes = 0
        var truncated = rawRows.count > maxRows

        for row in rawRows.prefix(maxRows) {
            let rowBytes = jsonByteCount(of: row)
            if bytes + rowBytes > maxBytes {
                truncated = true
                break
            }
            bytes += rowBytes
            rows.append(row)
        }
        return (rows, truncated)
    }

    static func jsonByteCount(of row: [DisplayValue]) -> Int {
        var count = 2 // [ ]
        for (index, value) in row.enumerated() {
            if index > 0 { count += 1 }
            count += jsonByteCount(of: value)
        }
        return count
    }

    private static func jsonByteCount(of value: DisplayValue) -> Int {
        switch value {
        case .null: return 4
        case .bool(let flag): return flag ? 4 : 5
        case .number(let number): return String(number).utf8.count
        case .string(let text): return text.utf8.count + 2
        case .binary(let data): return (data.count + 2) / 3 * 4 + 2
        case .array(let values):
            var count = 2
            for (index, element) in values.enumerated() {
                if index > 0 { count += 1 }
                count += jsonByteCount(of: element)
            }
            return count
        case .object(let pairs):
            var count = 2
            for (index, pair) in pairs.enumerated() {
                if index > 0 { count += 1 }
                count += pair.key.utf8.count + 3
                count += jsonByteCount(of: pair.value)
            }
            return count
        }
    }

    // MARK: - column metadata

    /// OIDs rendered right-aligned/numeric by the Electron adapter.
    static let numericTypeOIDs: Set<PostgresDataType> = [
        .int2, .int4, .int8, .float4, .float8, .numeric, .money, .oid,
    ]

    /// Lowercase builtin type names matching the Electron adapter's naming.
    static func typeName(of type: PostgresDataType) -> String {
        switch type {
        case .bool: "bool"
        case .bytea: "bytea"
        case .char: "char"
        case .name: "name"
        case .int8: "int8"
        case .int2: "int2"
        case .int4: "int4"
        case .regproc: "regproc"
        case .text: "text"
        case .oid: "oid"
        case .json: "json"
        case .xml: "xml"
        case .point: "point"
        case .float4: "float4"
        case .float8: "float8"
        case .unknown: "unknown"
        case .money: "money"
        case .macaddr: "macaddr"
        case .inet: "inet"
        case .cidr: "cidr"
        case .macaddr8: "macaddr8"
        case .bpchar: "bpchar"
        case .varchar: "varchar"
        case .date: "date"
        case .time: "time"
        case .timestamp: "timestamp"
        case .timestamptz: "timestamptz"
        case .interval: "interval"
        case .timetz: "timetz"
        case .uuid: "uuid"
        case .jsonb: "jsonb"
        case .numeric: "numeric"
        default: "oid:\(type.rawValue)"
        }
    }

    /// Builds deduplicated column metadata; a repeated name gets a `:N` suffix
    /// exactly like the Electron adapter's column keys.
    static func columnMetas(_ columns: [(name: String, dataType: PostgresDataType)]) -> [ColumnMeta] {
        var counts: [String: Int] = [:]
        return columns.map { column in
            let count = counts[column.name, default: 0]
            counts[column.name] = count + 1
            return ColumnMeta(
                name: count == 0 ? column.name : "\(column.name):\(count)",
                typeName: typeName(of: column.dataType),
                numeric: numericTypeOIDs.contains(column.dataType))
        }
    }
}

extension Int64 {
    /// Floor division (Swift's `/` truncates toward zero).
    func divideFloor(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0) && ((self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}
