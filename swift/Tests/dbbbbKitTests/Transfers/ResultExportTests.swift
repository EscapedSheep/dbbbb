import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Export semantics ported from the Electron `result-export.test.ts`: row
/// results become CRLF CSV with a header, document results become canonical
/// JSONL, and values without a portable representation fail closed.
final class ResultExportTests: XCTestCase {
    private let meta = ResultMeta(count: 0, truncated: false, elapsedMilliseconds: 0)

    private func columns(_ names: [String]) -> [ColumnMeta] {
        names.map { ColumnMeta(name: $0, typeName: "text") }
    }

    // MARK: - CSV export

    func testCSVExportScalars() throws {
        let result = QueryResult.rows(
            columns: columns(["id", "name", "active", "note"]),
            rows: [
                [.number(1), .string("Ada"), .bool(true), .null],
                [.number(2), .string("Bob"), .bool(false), .string("x")],
            ],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        XCTAssertEqual(exported.fileExtension, "csv")
        XCTAssertEqual(exported.rows, 2)
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "id,name,active,note\r\n1,Ada,true,\r\n2,Bob,false,x\r\n")
    }

    func testCSVExportQuotingAndNumbers() throws {
        let result = QueryResult.rows(
            columns: columns(["text", "amount"]),
            rows: [
                [.string("a,b\"c\nd"), .number(2.5)],
                // Precision-sensitive values cross as strings and stay strings.
                [.string("9007199254740993"), .number(-4)],
            ],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "text,amount\r\n\"a,b\"\"c\nd\",2.5\r\n9007199254740993,-4\r\n")
    }

    func testCSVExportNestedValuesBecomeCanonicalJSON() throws {
        let result = QueryResult.rows(
            columns: columns(["payload"]),
            rows: [[.object([("b", .number(2)), ("a", .array([.null, .string("s")]))])]],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        // Canonical JSON sorts keys and gets quoted because it contains commas.
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "payload\r\n\"{\"\"a\"\":[null,\"\"s\"\"],\"\"b\"\":2}\"\r\n")
    }

    func testCSVExportRejectsUnsupportedValues() {
        let binary = QueryResult.rows(
            columns: columns(["blob"]), rows: [[.binary(Data([1, 2]))]], meta: meta)
        XCTAssertThrowsError(try ResultExporter.exportData(for: binary)) { error in
            XCTAssertEqual(error as? ResultExportError, .unsupportedValue)
        }
        let nonFinite = QueryResult.rows(
            columns: columns(["n"]), rows: [[.number(.infinity)]], meta: meta)
        XCTAssertThrowsError(try ResultExporter.exportData(for: nonFinite)) { error in
            XCTAssertEqual(error as? ResultExportError, .unsupportedValue)
        }
        let ragged = QueryResult.rows(
            columns: columns(["a", "b"]), rows: [[.number(1)]], meta: meta)
        XCTAssertThrowsError(try ResultExporter.exportData(for: ragged)) { error in
            XCTAssertEqual(error as? ResultExportError, .invalidShape)
        }
    }

    // MARK: - CSV formula-injection neutralization

    func testCSVExportNeutralizesFormulaCellsAndHeaders() throws {
        let result = QueryResult.rows(
            columns: columns(["=cmd", "name"]),
            rows: [
                [.string("=HYPERLINK(\"http://evil\")"), .string("+1+2")],
                [.string("-2+3"), .string("@SUM(1)")],
            ],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "'=cmd,name\r\n"
                + "\"'=HYPERLINK(\"\"http://evil\"\")\",'+1+2\r\n"
                + "'-2+3,'@SUM(1)\r\n")
    }

    func testCSVExportNeutralizationLeavesOtherCellsAlone() throws {
        let result = QueryResult.rows(
            columns: columns(["plain", "n"]),
            rows: [
                // Null, empty string, numbers, and ordinary text are untouched
                // (a numeric -4 must not gain a quote; only strings do).
                [.null, .number(-4)],
                [.string(""), .number(2.5)],
                [.string("safe text"), .bool(true)],
                [.string("=already"), .string(" '=-prefixed")],
            ],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "plain,n\r\n"
                + ",-4\r\n"
                + ",2.5\r\n"
                + "safe text,true\r\n"
                + "'=already, '=-prefixed\r\n")
    }

    // MARK: - JSONL export

    func testJSONLExportCanonicalEJSONDocuments() throws {
        let result = QueryResult.documents(
            [
                .object([
                    ("title", .string("café")),
                    ("price", .string("19.99")), // decimals cross as strings
                    ("tags", .array([.string("a"), .number(3)])),
                    ("_id", .string("abc123")),
                ]),
                .object([("n", .bool(false))]),
            ],
            meta: meta)
        let exported = try ResultExporter.exportData(for: result)
        XCTAssertEqual(exported.fileExtension, "jsonl")
        XCTAssertEqual(exported.rows, 2)
        // Canonical EJSON: original key order (no sorting), bare numbers as
        // $numberDouble so BSON doubles survive a re-import.
        XCTAssertEqual(
            String(decoding: exported.data, as: UTF8.self),
            "{\"title\":\"café\",\"price\":\"19.99\",\"tags\":[\"a\",{\"$numberDouble\":\"3.0\"}],\"_id\":\"abc123\"}\n"
                + "{\"n\":false}\n")
    }

    func testJSONLExportRejectsNonDocuments() {
        let result = QueryResult.documents([.array([.number(1)])], meta: meta)
        XCTAssertThrowsError(try ResultExporter.exportData(for: result)) { error in
            XCTAssertEqual(error as? ResultExportError, .invalidShape)
        }
    }

    // MARK: - Canonical JSON

    func testCanonicalJSONEscaping() throws {
        XCTAssertEqual(try CanonicalJSON.serialize(.string("a\"b\\c\td\u{01}e")),
                       "\"a\\\"b\\\\c\\td\\u0001e\"")
        XCTAssertEqual(try CanonicalJSON.serialize(.string("héllo")), "\"héllo\"")
        XCTAssertEqual(try CanonicalJSON.serialize(.number(0)), "0")
        XCTAssertEqual(try CanonicalJSON.serialize(.number(-0.5)), "-0.5")
        XCTAssertEqual(try CanonicalJSON.serialize(.null), "null")
    }
}
