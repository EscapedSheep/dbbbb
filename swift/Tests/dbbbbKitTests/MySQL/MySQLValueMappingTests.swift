import XCTest
import Foundation
import dbbbbCore
@testable import dbbbbKit
@testable import MySQLNIO
import NIOCore

final class MySQLValueMappingTests: XCTestCase {
    private func column(
        name: String = "c",
        type: MySQLProtocol.DataType,
        characterSet: MySQLProtocol.CharacterSet = 33, // utf8_general_ci
        columnLength: UInt32 = 255,
        unsigned: Bool = false
    ) -> MySQLProtocol.ColumnDefinition41 {
        MySQLProtocol.ColumnDefinition41(
            catalog: "def",
            schema: "test",
            table: "t",
            orgTable: "t",
            name: name,
            orgName: name,
            characterSet: characterSet,
            columnLength: columnLength,
            columnType: type,
            flags: unsigned ? .COLUMN_UNSIGNED : [],
            decimals: 0
        )
    }

    private func buffer(_ text: String) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
        buffer.writeString(text)
        return buffer
    }

    private func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    // MARK: - Nulls and text

    func testNullBufferIsNull() {
        let value = MySQLValueMapping.displayValue(column: column(type: .varString), buffer: nil)
        XCTAssertEqual(value, .null)
    }

    func testVarStringIsString() {
        let value = MySQLValueMapping.displayValue(column: column(type: .varString), buffer: buffer("hello"))
        XCTAssertEqual(value, .string("hello"))
    }

    func testEmptyStringIsEmptyNotNull() {
        let value = MySQLValueMapping.displayValue(column: column(type: .varString), buffer: buffer(""))
        XCTAssertEqual(value, .string(""))
    }

    func testBinaryCharsetVarStringIsBinary() {
        let value = MySQLValueMapping.displayValue(
            column: column(type: .varString, characterSet: .binary),
            buffer: buffer([0xDE, 0xAD])
        )
        XCTAssertEqual(value, .binary(Data([0xDE, 0xAD])))
    }

    // MARK: - Integers and bools

    func testTinyIntOneIsBool() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .tiny, columnLength: 1), buffer: buffer("1")),
            .bool(true)
        )
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .tiny, columnLength: 1), buffer: buffer("0")),
            .bool(false)
        )
    }

    func testTinyIntOneWithLargerValueStaysNumeric() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .tiny, columnLength: 1), buffer: buffer("42")),
            .number(42)
        )
    }

    func testRegularIntegersAreNumbers() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .long), buffer: buffer("-12")),
            .number(-12)
        )
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .year), buffer: buffer("2024")),
            .number(2024)
        )
    }

    func testBigIntWithinSafeRangeIsNumber() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longlong), buffer: buffer("9007199254740991")),
            .number(9_007_199_254_740_991)
        )
    }

    func testBigIntBeyondSafeRangeIsString() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longlong), buffer: buffer("9223372036854775807")),
            .string("9223372036854775807")
        )
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longlong), buffer: buffer("-9223372036854775808")),
            .string("-9223372036854775808")
        )
    }

    func testUnsignedBigIntBeyondSafeRangeIsString() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longlong, unsigned: true), buffer: buffer("18446744073709551615")),
            .string("18446744073709551615")
        )
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longlong, unsigned: true), buffer: buffer("42")),
            .number(42)
        )
    }

    // MARK: - Floating point and decimal

    func testDoubleIsNumber() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .double), buffer: buffer("1.5")),
            .number(1.5)
        )
    }

    func testDecimalIsString() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .newdecimal), buffer: buffer("123.4500")),
            .string("123.4500")
        )
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .decimal), buffer: buffer("0.1")),
            .string("0.1")
        )
    }

    // MARK: - Temporal values stay strings

    func testTemporalTypesAreStrings() {
        for type in [
            MySQLProtocol.DataType.date, .time, .datetime, .timestamp, .newdate,
        ] as [MySQLProtocol.DataType] {
            let value = MySQLValueMapping.displayValue(column: column(type: type), buffer: buffer("2024-01-02 03:04:05"))
            XCTAssertEqual(value, .string("2024-01-02 03:04:05"), "\(type)")
        }
    }

    // MARK: - Binary and JSON

    func testBitIsBinary() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .bit), buffer: buffer([0b101])),
            .binary(Data([0b101]))
        )
    }

    func testBlobWithBinaryCharsetIsBinary() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .blob, characterSet: .binary), buffer: buffer([1, 2, 3])),
            .binary(Data([1, 2, 3]))
        )
    }

    func testBlobWithTextCharsetIsString() {
        // TEXT columns share the BLOB wire type with a non-binary charset.
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .longBlob, characterSet: 33), buffer: buffer("text")),
            .string("text")
        )
    }

    func testJSONIsString() {
        XCTAssertEqual(
            MySQLValueMapping.displayValue(column: column(type: .json), buffer: buffer(#"{"a":1}"#)),
            .string(#"{"a":1}"#)
        )
    }

    // MARK: - Single-value truncation

    func testOversizedStringIsTruncatedWithMarker() {
        let text = String(repeating: "a", count: MySQLValueMapping.maxValueBytes + 10)
        let bounded = MySQLValueMapping.boundedString(text)
        XCTAssertTrue(bounded.hasSuffix(MySQLValueMapping.truncatedMarker(omittedBytes: 10)))
        XCTAssertEqual(bounded.count, MySQLValueMapping.maxValueBytes + MySQLValueMapping.truncatedMarker(omittedBytes: 10).count)
    }

    func testOversizedBinaryIsTruncatedWithMarker() {
        let data = Data(repeating: 0xAB, count: MySQLValueMapping.maxValueBytes + 7)
        let bounded = MySQLValueMapping.boundedBinary(data)
        XCTAssertEqual(bounded.count, MySQLValueMapping.maxValueBytes + MySQLValueMapping.truncatedMarker(omittedBytes: 7).utf8.count)
        XCTAssertTrue(bounded.starts(with: Data(repeating: 0xAB, count: 16)))
        XCTAssertTrue(bounded.suffix(3) == Data("es]".utf8))
    }

    // MARK: - Row budgets

    private func row(_ texts: [String?]) -> MySQLRow {
        let columns = texts.indices.map { column(name: "c\($0)", type: .varString) }
        let values: [ByteBuffer?] = texts.map { $0.map(buffer) }
        return MySQLRow(format: .text, columnDefinitions: columns, values: values)
    }

    func testRowCountBudgetTruncates() {
        let rows = (0..<5).map { row(["v\($0)"]) }
        let bounded = MySQLValueMapping.boundedRows(rawRows: rows, maxRows: 3, maxBytes: 1_000_000)
        XCTAssertEqual(bounded.rows.count, 3)
        XCTAssertTrue(bounded.truncated)
    }

    func testByteBudgetTruncates() {
        let rows = (0..<10).map { _ in row([String(repeating: "x", count: 100)]) }
        let bounded = MySQLValueMapping.boundedRows(rawRows: rows, maxRows: 10, maxBytes: 250)
        XCTAssertEqual(bounded.rows.count, 2)
        XCTAssertTrue(bounded.truncated)
    }

    func testNoTruncationWhenWithinBudgets() {
        let rows = [row(["a", "b"]), row(["c", nil])]
        let bounded = MySQLValueMapping.boundedRows(rawRows: rows, maxRows: 10, maxBytes: 1_000)
        XCTAssertEqual(bounded.rows.count, 2)
        XCTAssertFalse(bounded.truncated)
        XCTAssertEqual(bounded.rows[1], [.string("c"), .null])
    }

    // MARK: - Column metadata

    func testColumnMetaTypeNamesAndNumericFlag() {
        let meta = MySQLValueMapping.columnMeta([
            column(name: "id", type: .longlong),
            column(name: "price", type: .newdecimal),
            column(name: "name", type: .varString),
        ])
        XCTAssertEqual(meta.map(\.name), ["id", "price", "name"])
        XCTAssertEqual(meta.map(\.typeName), ["longlong", "newdecimal", "var_string"])
        XCTAssertEqual(meta.map(\.numeric), [true, true, false])
    }
}

final class MySQLErrorSanitizerTests: XCTestCase {
    private struct PlainError: Error, CustomStringConvertible {
        let description: String
    }

    private func nsError(_ message: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func testPasswordIsRedactedInPlainAndEncodedForm() {
        let error = MySQLErrorSanitizer.sanitize(
            action: "MySQL query failed",
            error: nsError("Access denied for user 'u' with password hunter2"),
            secrets: ["hunter2"]
        )
        XCTAssertEqual(error.userMessage, "MySQL query failed: Access denied for user 'u' with password [redacted]")

        let encoded = MySQLErrorSanitizer.sanitize(
            action: "MySQL query failed",
            error: nsError("login failed for credential my%20secret here"),
            secrets: ["my secret"]
        )
        XCTAssertFalse(encoded.userMessage.contains("my%20secret"))
        XCTAssertTrue(encoded.userMessage.contains("[redacted]"))
    }

    func testCredentialURIPatternIsRedacted() {
        let error = MySQLErrorSanitizer.sanitize(
            action: "Could not connect to MySQL",
            error: nsError("dial mysql://root:topsecret@db.internal:3306/app failed"),
            secrets: []
        )
        XCTAssertEqual(error.userMessage, "Could not connect to MySQL: dial mysql://[redacted]@db.internal:3306/app failed")
    }

    func testPasswordEqualsPatternIsRedacted() {
        let error = MySQLErrorSanitizer.sanitize(
            action: "MySQL query failed",
            error: nsError(#"invalid option password="s3cr3t" rest"#),
            secrets: []
        )
        XCTAssertEqual(error.userMessage, "MySQL query failed: invalid option password=[redacted] rest")
    }

    func testControlCharactersAreStrippedAndLengthCapped() {
        let long = String(repeating: "x", count: 1_000) + "\u{0}\u{7}"
        let error = MySQLErrorSanitizer.sanitize(action: "MySQL query failed", error: nsError(long), secrets: [])
        XCTAssertLessThanOrEqual(error.userMessage.count, "MySQL query failed: ".count + 600)
        XCTAssertFalse(error.userMessage.contains("\u{0}"))
    }

    func testEmptyMessageGetsFallback() {
        let error = MySQLErrorSanitizer.sanitize(action: "MySQL query failed", error: PlainError(description: ""), secrets: [])
        XCTAssertTrue(error.userMessage.hasPrefix("MySQL query failed: "))
    }

    func testServerErrorCodeIsPreserved() {
        let packet = MySQLProtocol.ERR_Packet(
            errorCode: MySQLProtocol.ErrorCode(integerLiteral: 1094),
            sqlStateMarker: "#",
            sqlState: "HY000",
            errorMessage: "Unknown thread id: 42"
        )
        let error = MySQLErrorSanitizer.sanitize(
            action: "Could not cancel MySQL query",
            error: MySQLError.server(packet),
            secrets: []
        )
        XCTAssertTrue(error.userMessage.contains("Unknown thread id: 42"), error.userMessage)
        XCTAssertTrue(error.userMessage.hasSuffix("(ER_NO_SUCH_THREAD)"), error.userMessage)
    }

    func testEmptySecretsAreIgnored() {
        let error = MySQLErrorSanitizer.sanitize(
            action: "MySQL query failed",
            error: nsError("some message"),
            secrets: [""]
        )
        XCTAssertEqual(error.userMessage, "MySQL query failed: some message")
    }
}
