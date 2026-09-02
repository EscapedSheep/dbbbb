import Foundation
import dbbbbCore

/// Byte limits for delimited transfers, ported from the Electron
/// `delimited.ts` defaults. All counts are UTF-8 bytes.
struct TransferLimits: Sendable, Equatable {
    /// Decoded bytes in one field. For JSONL, the complete JSON value is one field.
    var maxFieldBytes = 8 * 1024 * 1024
    /// Bytes in one logical CSV record or one JSONL line, including its line ending.
    var maxLineBytes = 32 * 1024 * 1024
    /// Raw bytes consumed from the input.
    var maxTotalBytes = 1024 * 1024 * 1024

    static let `default` = TransferLimits()
}

/// Parser/serializer failures. Messages never contain file paths, so they are
/// safe to surface verbatim.
enum DelimitedError: dbbbbError, Equatable {
    enum Limit: String, Sendable {
        case field, line, total
    }

    case invalidCSV(line: Int, detail: String)
    case invalidJSONL(line: Int)
    case limitExceeded(limit: Limit, maximumBytes: Int, line: Int?)

    var userMessage: String {
        switch self {
        case .invalidCSV(let line, let detail):
            "Invalid CSV at line \(line): \(detail)"
        case .invalidJSONL(let line):
            "Invalid JSON on JSONL line \(line)."
        case .limitExceeded(let limit, let maximumBytes, let line):
            "Delimited transfer \(limit.rawValue) limit of \(maximumBytes) bytes was exceeded"
                + (line.map { " at line \($0)" } ?? "") + "."
        }
    }
}

/// Exact UTF-8 length of one code point (the Electron `utf8Bytes`).
/// Parsers iterate unicode *scalars*, not grapheme clusters: JS iterates code
/// points and Swift's `Character` merges CRLF into one cluster, which would
/// hide record endings.
private func utf8Bytes(_ scalar: Unicode.Scalar) -> Int {
    let codePoint = scalar.value
    if codePoint < 0x80 { return 1 }
    if codePoint < 0x800 { return 2 }
    if codePoint < 0x10000 { return 3 }
    return 4
}

/// Incremental RFC4180-style CSV record parser, ported from the Electron
/// `parseCsv`: CRLF and bare LF/CR end records, CR/LF inside a quoted field
/// is preserved verbatim, a leading BOM is skipped, and `""` inside a quoted
/// field is one literal quote. Feed text with `append`; completed records
/// come back per call, and `finish` flushes a trailing unterminated record.
struct CSVParser {
    private enum State {
        case fieldStart, unquoted, quoted, afterQuote
    }

    private let delimiter: Unicode.Scalar
    private let limits: TransferLimits

    private var state: State = .fieldStart
    private var field = ""
    private var fieldBytes = 0
    private var fields: [String] = []
    private var recordBytes = 0
    private var totalBytes = 0
    private var recordTouched = false
    private(set) var recordNumber = 1
    private(set) var lineNumber = 1
    private var previousPhysicalCharacterWasCR = false
    private var skipLFAfterRecordCR = false
    private var atFileStart = true

    /// The delimiter must be one character other than a quote or newline.
    init(delimiter: Character = ",", limits: TransferLimits = .default) throws {
        let scalars = String(delimiter).unicodeScalars
        guard scalars.count == 1, let resolved = scalars.first,
              resolved != "\"", resolved != "\r", resolved != "\n"
        else {
            throw DelimitedError.invalidCSV(line: 0, detail: "the delimiter is invalid.")
        }
        self.delimiter = resolved
        self.limits = limits
    }

    /// Feeds decoded text; returns every record completed by this chunk.
    mutating func append(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        for scalar in text.unicodeScalars {
            totalBytes += utf8Bytes(scalar)
            if totalBytes > limits.maxTotalBytes {
                throw DelimitedError.limitExceeded(
                    limit: .total, maximumBytes: limits.maxTotalBytes, line: lineNumber)
            }
            if atFileStart {
                atFileStart = false
                if scalar == "\u{FEFF}" { continue }
            }

            if skipLFAfterRecordCR && scalar == "\n" {
                skipLFAfterRecordCR = false
                advancePhysicalLine(scalar)
                continue
            }
            skipLFAfterRecordCR = false

            recordBytes += utf8Bytes(scalar)
            if recordBytes > limits.maxLineBytes {
                throw DelimitedError.limitExceeded(
                    limit: .line, maximumBytes: limits.maxLineBytes, line: lineNumber)
            }

            if state == .quoted {
                recordTouched = true
                if scalar == "\"" {
                    state = .afterQuote
                } else {
                    try appendField(scalar)
                }
                advancePhysicalLine(scalar)
                continue
            }

            if state == .afterQuote {
                if scalar == "\"" {
                    try appendField("\"")
                    state = .quoted
                } else if scalar == delimiter {
                    finishField()
                    recordTouched = true
                } else if scalar == "\r" || scalar == "\n" {
                    records.append(takeRecord())
                    if scalar == "\r" { skipLFAfterRecordCR = true }
                } else {
                    throw DelimitedError.invalidCSV(
                        line: lineNumber,
                        detail: "unexpected character after a closing quote.")
                }
                advancePhysicalLine(scalar)
                continue
            }

            if scalar == delimiter {
                finishField()
                recordTouched = true
            } else if scalar == "\r" || scalar == "\n" {
                records.append(takeRecord())
                if scalar == "\r" { skipLFAfterRecordCR = true }
            } else if scalar == "\"" {
                guard state == .fieldStart else {
                    throw DelimitedError.invalidCSV(
                        line: lineNumber, detail: "quote inside an unquoted field.")
                }
                state = .quoted
                recordTouched = true
            } else {
                try appendField(scalar)
                state = .unquoted
                recordTouched = true
            }
            advancePhysicalLine(scalar)
        }
        return records
    }

    /// Flushes the trailing record (if any) once the input is exhausted.
    mutating func finish() throws -> [String]? {
        if state == .quoted {
            throw DelimitedError.invalidCSV(
                line: lineNumber, detail: "quoted field was not closed.")
        }
        if recordTouched || !fields.isEmpty || state != .fieldStart {
            return takeRecord()
        }
        return nil
    }

    private mutating func appendField(_ scalar: Unicode.Scalar) throws {
        field.unicodeScalars.append(scalar)
        fieldBytes += utf8Bytes(scalar)
        if fieldBytes > limits.maxFieldBytes {
            throw DelimitedError.limitExceeded(
                limit: .field, maximumBytes: limits.maxFieldBytes, line: lineNumber)
        }
    }

    private mutating func finishField() {
        fields.append(field)
        field = ""
        fieldBytes = 0
        state = .fieldStart
    }

    private mutating func takeRecord() -> [String] {
        finishField()
        let record = fields
        fields = []
        recordBytes = 0
        recordTouched = false
        recordNumber += 1
        return record
    }

    private mutating func advancePhysicalLine(_ scalar: Unicode.Scalar) {
        if scalar == "\r" {
            lineNumber += 1
            previousPhysicalCharacterWasCR = true
        } else if scalar == "\n" {
            if !previousPhysicalCharacterWasCR { lineNumber += 1 }
            previousPhysicalCharacterWasCR = false
        } else {
            previousPhysicalCharacterWasCR = false
        }
    }
}

/// CSV record serialization, ported from the Electron `serializeCsv`: fields
/// containing the delimiter, a quote, or CR/LF are quoted and inner quotes are
/// doubled; records end with CRLF.
enum CSVSerializer {
    static func field(_ text: String, delimiter: Character = ",") -> String {
        if text.contains("\"") || text.contains(delimiter)
            || text.contains("\r") || text.contains("\n") {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    static func record(_ fields: [String], delimiter: Character = ",") -> String {
        fields.map { field($0, delimiter: delimiter) }.joined(separator: String(delimiter)) + "\r\n"
    }
}

/// Incremental JSON Lines parser, ported from the Electron `parseJsonLines`:
/// one JSON value per LF/CRLF-delimited line, a leading BOM is skipped, and a
/// trailing unterminated line is flushed by `finish`. Line contents come back
/// raw; the caller owns JSON parsing so MongoDB lines go through the canonical
/// EJSON codec.
struct JSONLinesParser {
    private let limits: TransferLimits
    private let skipEmptyLines: Bool

    private var line = ""
    private var lineBytes = 0
    private var fieldBytes = 0
    private var totalBytes = 0
    private(set) var lineNumber = 1
    private var atFileStart = true

    init(limits: TransferLimits = .default, skipEmptyLines: Bool = false) {
        self.limits = limits
        self.skipEmptyLines = skipEmptyLines
    }

    /// Feeds decoded text; returns every line completed by this chunk. Empty
    /// lines are dropped when `skipEmptyLines` is set, otherwise returned for
    /// the caller to reject.
    mutating func append(_ text: String) throws -> [(lineNumber: Int, content: String)] {
        var lines: [(lineNumber: Int, content: String)] = []
        for scalar in text.unicodeScalars {
            let scalarBytes = utf8Bytes(scalar)
            totalBytes += scalarBytes
            if totalBytes > limits.maxTotalBytes {
                throw DelimitedError.limitExceeded(
                    limit: .total, maximumBytes: limits.maxTotalBytes, line: lineNumber)
            }
            if atFileStart {
                atFileStart = false
                if scalar == "\u{FEFF}" { continue }
            }

            lineBytes += scalarBytes
            if lineBytes > limits.maxLineBytes {
                throw DelimitedError.limitExceeded(
                    limit: .line, maximumBytes: limits.maxLineBytes, line: lineNumber)
            }

            if scalar == "\n" {
                if let parsed = takeLine() { lines.append(parsed) }
            } else {
                fieldBytes += scalarBytes
                if fieldBytes > limits.maxFieldBytes {
                    throw DelimitedError.limitExceeded(
                        limit: .field, maximumBytes: limits.maxFieldBytes, line: lineNumber)
                }
                line.unicodeScalars.append(scalar)
            }
        }
        return lines
    }

    /// Flushes the trailing unterminated line, if any.
    mutating func finish() throws -> (lineNumber: Int, content: String)? {
        guard !line.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> (lineNumber: Int, content: String)? {
        let raw = line
        let number = lineNumber
        line = ""
        lineBytes = 0
        fieldBytes = 0
        lineNumber += 1
        let content = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if skipEmptyLines, content.trimmingCharacters(in: .whitespaces).isEmpty {
            return nil
        }
        return (number, content)
    }
}

/// Incremental UTF-8 decoder for file chunks: bytes are buffered until they
/// form complete scalar sequences, so multi-byte characters split across read
/// boundaries are never mangled. Invalid bytes become U+FFFD, matching Node's
/// `StringDecoder`.
struct UTF8ChunkDecoder {
    private var pending: [UInt8] = []

    mutating func decode(_ bytes: some Collection<UInt8>) -> String {
        guard !bytes.isEmpty else { return "" }
        pending.append(contentsOf: bytes)
        let complete = Self.completePrefixLength(pending)
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending.removeFirst(complete)
        return text
    }

    /// Flushes any bytes left after the final chunk.
    mutating func finish() -> String {
        guard !pending.isEmpty else { return "" }
        let text = String(decoding: pending, as: UTF8.self)
        pending = []
        return text
    }

    /// Length of the prefix that ends on a complete UTF-8 sequence boundary.
    private static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var index = bytes.count - 1
        let lowerBound = max(0, bytes.count - 3)
        while index >= lowerBound {
            let byte = bytes[index]
            if byte & 0xC0 != 0x80 {
                let length = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                return length <= bytes.count - index ? bytes.count : index
            }
            index -= 1
        }
        // All trailing bytes are continuation bytes (already invalid); decode as-is.
        return bytes.count
    }
}
