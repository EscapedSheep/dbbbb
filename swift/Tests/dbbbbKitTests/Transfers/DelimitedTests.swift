import Foundation
import XCTest
@testable import dbbbbKit

/// Port of the Electron `delimited.test.ts` edge cases: quoting, embedded
/// newlines, CRLF/CR handling, BOM, byte limits, and chunked feeding.
final class DelimitedTests: XCTestCase {
    // MARK: - CSV parsing

    private func parse(_ text: String, chunkBy: Int? = nil) throws -> [[String]] {
        var parser = try CSVParser()
        var records: [[String]] = []
        if let chunkBy {
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunkBy, limitedBy: text.endIndex) ?? text.endIndex
                records.append(contentsOf: try parser.append(String(text[index..<end])))
                index = end
            }
        } else {
            records.append(contentsOf: try parser.append(text))
        }
        if let trailing = try parser.finish() {
            records.append(trailing)
        }
        return records
    }

    func testBasicRecordsWithMixedEndings() throws {
        XCTAssertEqual(try parse("a,b\r\nc,d\n"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(try parse("a,b\rc,d\r"), [["a", "b"], ["c", "d"]])
        XCTAssertEqual(try parse("a,b"), [["a", "b"]])
    }

    func testEmptyFieldsAndEmptyInput() throws {
        XCTAssertEqual(try parse("a,,\n"), [["a", "", ""]])
        XCTAssertEqual(try parse(","), [["", ""]])
        XCTAssertEqual(try parse(""), [])
        // A file containing only a newline yields one empty field.
        XCTAssertEqual(try parse("\n"), [[""]])
    }

    func testQuotedFields() throws {
        XCTAssertEqual(try parse("\"a\",\"b\"\n"), [["a", "b"]])
        // Escaped quotes and embedded delimiter.
        XCTAssertEqual(try parse("\"a\"\"b\",\"c,d\"\n"), [["a\"b", "c,d"]])
        // Embedded newlines survive verbatim, including CRLF inside quotes.
        XCTAssertEqual(try parse("\"a\nb\",\"c\r\nd\"\n"), [["a\nb", "c\r\nd"]])
        // Empty quoted field.
        XCTAssertEqual(try parse("\"\",x\n"), [["", "x"]])
    }

    func testBOMIsSkippedOnlyAtFileStart() throws {
        XCTAssertEqual(try parse("\u{FEFF}a,b\n"), [["a", "b"]])
        // A BOM elsewhere is data.
        XCTAssertEqual(try parse("a,\u{FEFF}b\n"), [["a", "\u{FEFF}b"]])
    }

    func testCRLFIsOneRecordEnding() throws {
        // The LF of a record-ending CRLF must not start a phantom empty record.
        XCTAssertEqual(try parse("a\r\nb\r\n"), [["a"], ["b"]])
        // Bare CR at EOF ends the record.
        XCTAssertEqual(try parse("a,b\r"), [["a", "b"]])
    }

    func testChunkedFeeding() throws {
        let text = "\"quo\r\nted\",se\u{00E9}cond\r\n\"a\"\"b\",c\r\nlast,one"
        let whole = try parse(text)
        XCTAssertEqual(whole, [["quo\r\nted", "se\u{00E9}cond"], ["a\"b", "c"], ["last", "one"]])
        // Byte-by-byte feeding must produce identical records.
        XCTAssertEqual(try parse(text, chunkBy: 1), whole)
        XCTAssertEqual(try parse(text, chunkBy: 3), whole)
    }

    func testInvalidCSV() throws {
        // Unclosed quoted field.
        XCTAssertThrowsError(try parse("\"abc")) { error in
            XCTAssertEqual(error as? DelimitedError, .invalidCSV(line: 1, detail: "quoted field was not closed."))
        }
        // Character after a closing quote.
        XCTAssertThrowsError(try parse("\"a\"x\n")) { error in
            guard case .invalidCSV = error as? DelimitedError else {
                return XCTFail("expected invalidCSV, got \(error)")
            }
        }
        // Quote inside an unquoted field.
        XCTAssertThrowsError(try parse("ab\"c\n")) { error in
            guard case .invalidCSV = error as? DelimitedError else {
                return XCTFail("expected invalidCSV, got \(error)")
            }
        }
        // A quote after a delimiter starts a quoted field — legal.
        XCTAssertEqual(try parse("a,\"b\"\n"), [["a", "b"]])
    }

    func testDelimiterValidation() throws {
        XCTAssertThrowsError(try CSVParser(delimiter: "\""))
        XCTAssertThrowsError(try CSVParser(delimiter: "\n"))
        XCTAssertThrowsError(try CSVParser(delimiter: "\r"))
        var semicolon = try CSVParser(delimiter: ";")
        XCTAssertEqual(try semicolon.append("a;b\n"), [["a", "b"]])
    }

    func testByteLimits() throws {
        var smallField = try CSVParser(limits: TransferLimits(
            maxFieldBytes: 4, maxLineBytes: 1024, maxTotalBytes: 1024))
        XCTAssertThrowsError(try smallField.append("abcde")) { error in
            XCTAssertEqual(
                error as? DelimitedError,
                .limitExceeded(limit: .field, maximumBytes: 4, line: 1))
        }

        var smallLine = try CSVParser(limits: TransferLimits(
            maxFieldBytes: 1024, maxLineBytes: 5, maxTotalBytes: 1024))
        XCTAssertThrowsError(try smallLine.append("ab,cde")) { error in
            guard case .limitExceeded(let limit, _, _) = error as? DelimitedError, limit == .line else {
                return XCTFail("expected line limit, got \(error)")
            }
        }

        var smallTotal = try CSVParser(limits: TransferLimits(
            maxFieldBytes: 1024, maxLineBytes: 1024, maxTotalBytes: 3))
        XCTAssertThrowsError(try smallTotal.append("abcd")) { error in
            guard case .limitExceeded(let limit, _, _) = error as? DelimitedError, limit == .total else {
                return XCTFail("expected total limit, got \(error)")
            }
        }

        // Multi-byte characters count their UTF-8 bytes.
        var multibyte = try CSVParser(limits: TransferLimits(
            maxFieldBytes: 2, maxLineBytes: 1024, maxTotalBytes: 1024))
        XCTAssertThrowsError(try multibyte.append("\u{00E9}\u{00E9}"))
    }

    func testLineAndRecordNumbers() throws {
        var parser = try CSVParser()
        _ = try parser.append("a,b\r\n\"x\ny\",z\r\n")
        XCTAssertEqual(parser.recordNumber, 3)
        XCTAssertEqual(parser.lineNumber, 4)
    }

    // MARK: - CSV serialization

    func testCSVSerializer() {
        XCTAssertEqual(CSVSerializer.field("plain"), "plain")
        XCTAssertEqual(CSVSerializer.field(""), "")
        XCTAssertEqual(CSVSerializer.field("a,b"), "\"a,b\"")
        XCTAssertEqual(CSVSerializer.field("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(CSVSerializer.field("a\nb"), "\"a\nb\"")
        XCTAssertEqual(CSVSerializer.field("a\rb"), "\"a\rb\"")
        XCTAssertEqual(CSVSerializer.record(["a", "b c", ""]), "a,b c,\r\n")
        // Serializer output round-trips through the parser.
        let text = CSVSerializer.record(["x,y", "\"q\"", "line\nbreak"]) + CSVSerializer.record(["1", "2", "3"])
        var parser = try! CSVParser()
        var records = try! parser.append(text)
        if let trailing = try! parser.finish() { records.append(trailing) }
        XCTAssertEqual(records, [["x,y", "\"q\"", "line\nbreak"], ["1", "2", "3"]])
    }

    // MARK: - JSONL parsing

    private func parseJSONL(
        _ text: String,
        skipEmptyLines: Bool = false,
        chunkBy: Int? = nil
    ) throws -> [(lineNumber: Int, content: String)] {
        var parser = JSONLinesParser(skipEmptyLines: skipEmptyLines)
        var lines: [(lineNumber: Int, content: String)] = []
        if let chunkBy {
            var index = text.startIndex
            while index < text.endIndex {
                let end = text.index(index, offsetBy: chunkBy, limitedBy: text.endIndex) ?? text.endIndex
                lines.append(contentsOf: try parser.append(String(text[index..<end])))
                index = end
            }
        } else {
            lines.append(contentsOf: try parser.append(text))
        }
        if let trailing = try parser.finish() {
            lines.append(trailing)
        }
        return lines
    }

    func testJSONLLines() throws {
        let lines = try parseJSONL("{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(lines.map(\.lineNumber), [1, 2])
        XCTAssertEqual(lines.map(\.content), ["{\"a\":1}", "{\"b\":2}"])
        // CRLF endings lose the CR.
        XCTAssertEqual(try parseJSONL("{\"a\":1}\r\n").map(\.content), ["{\"a\":1}"])
        // Trailing unterminated line is flushed by finish().
        XCTAssertEqual(try parseJSONL("{\"a\":1}").map(\.content), ["{\"a\":1}"])
        // BOM skipped.
        XCTAssertEqual(try parseJSONL("\u{FEFF}{\"a\":1}\n").map(\.content), ["{\"a\":1}"])
        // Chunked feeding is transparent.
        XCTAssertEqual(try parseJSONL("{\"a\":1}\n{\"b\":2}", chunkBy: 1).map(\.content),
                       ["{\"a\":1}", "{\"b\":2}"])
    }

    func testJSONLEmptyLines() throws {
        // Without skipping, empty lines come back for the caller to reject.
        let kept = try parseJSONL("{\"a\":1}\n\n{\"b\":2}\n")
        XCTAssertEqual(kept.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(kept.map(\.content), ["{\"a\":1}", "", "{\"b\":2}"])
        let skipped = try parseJSONL("{\"a\":1}\n  \n{\"b\":2}\n", skipEmptyLines: true)
        XCTAssertEqual(skipped.map(\.lineNumber), [1, 3])
    }

    func testJSONLLimits() throws {
        var parser = JSONLinesParser(limits: TransferLimits(
            maxFieldBytes: 3, maxLineBytes: 1024, maxTotalBytes: 1024))
        XCTAssertThrowsError(try parser.append("abcd")) { error in
            guard case .limitExceeded(let limit, _, _) = error as? DelimitedError, limit == .field else {
                return XCTFail("expected field limit, got \(error)")
            }
        }
        var totalLimited = JSONLinesParser(limits: TransferLimits(
            maxFieldBytes: 1024, maxLineBytes: 1024, maxTotalBytes: 2))
        XCTAssertThrowsError(try totalLimited.append("abc")) { error in
            guard case .limitExceeded(let limit, _, _) = error as? DelimitedError, limit == .total else {
                return XCTFail("expected total limit, got \(error)")
            }
        }
    }

    // MARK: - UTF-8 chunk decoding

    func testUTF8ChunkDecoderSplitsMultibyteCharacters() {
        var decoder = UTF8ChunkDecoder()
        let euro = Array("\u{20AC}".utf8) // 3 bytes
        XCTAssertEqual(decoder.decode([euro[0]]), "")
        XCTAssertEqual(decoder.decode([euro[1]]), "")
        XCTAssertEqual(decoder.decode([euro[2]]), "\u{20AC}")
        XCTAssertEqual(decoder.finish(), "")

        var decoder2 = UTF8ChunkDecoder()
        XCTAssertEqual(decoder2.decode(Array("a\u{00E9}b".utf8)), "a\u{00E9}b")
    }

    func testUTF8ChunkDecoderInvalidBytesAndFinish() {
        var decoder = UTF8ChunkDecoder()
        XCTAssertEqual(decoder.decode([0x61, 0xFF, 0x62]), "a\u{FFFD}b")
        var trailing = UTF8ChunkDecoder()
        XCTAssertEqual(trailing.decode([0xE2, 0x82]), "")
        XCTAssertEqual(trailing.finish(), "\u{FFFD}")
    }
}
