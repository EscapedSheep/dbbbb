import XCTest
@testable import dbbbbKit

final class PostgresSupportTests: XCTestCase {
    private struct TestError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - Sanitizer

    func testSanitizerRedactsRawAndPercentEncodedSecrets() {
        let error = TestError(
            description: "auth failed for s3cr3t and s%20cr3t variant")
        let sanitized = PostgresErrorSanitizer.sanitized(
            action: "PostgreSQL query failed", error: error, secrets: ["s cr3t", "s3cr3t"])
        XCTAssertFalse(sanitized.userMessage.contains("s3cr3t"))
        XCTAssertFalse(sanitized.userMessage.contains("s cr3t"))
        XCTAssertFalse(sanitized.userMessage.contains("s%20cr3t"))
        XCTAssertTrue(sanitized.userMessage.hasPrefix("PostgreSQL query failed: "))
        XCTAssertNil(sanitized.sqlState)
    }

    func testSanitizerRedactsCredentialURIsAndPasswordFragments() {
        let error = TestError(
            description: "could not connect to postgres://admin:hunter2@db.internal:5432/app; "
                + "option password=hunter2, other passwd: 'hunter2' pwd=\"hunter2\"")
        let sanitized = PostgresErrorSanitizer.sanitized(
            action: "Could not connect", error: error, secrets: ["hunter2"])
        XCTAssertFalse(sanitized.userMessage.contains("hunter2"))
        XCTAssertFalse(sanitized.userMessage.contains("admin"))
        XCTAssertTrue(sanitized.userMessage.contains("postgresql://[redacted]@"))
    }

    func testSanitizerStripsControlCharactersAndCapsLength() {
        let noisy = String(repeating: "x", count: 1_000) + "\u{0}\u{7}\u{1b}tail"
        let sanitized = PostgresErrorSanitizer.sanitized(
            action: "A", error: TestError(description: noisy), secrets: [])
        XCTAssertEqual(sanitized.userMessage.count, 3 + PostgresErrorSanitizer.maxLength)
        XCTAssertFalse(sanitized.userMessage.contains("\u{0}"))
        XCTAssertFalse(sanitized.userMessage.contains("\u{7}"))
    }

    func testPercentEncodeMatchesEncodeURIComponentAlphabet() {
        XCTAssertEqual(PostgresErrorSanitizer.percentEncode("a b/c?d"), "a%20b%2Fc%3Fd")
        XCTAssertEqual(
            PostgresErrorSanitizer.percentEncode("-_.!~*'()ok"),
            "-_.!~*'()ok")
        XCTAssertEqual(PostgresErrorSanitizer.percentEncode("é"), "%C3%A9")
    }

    // MARK: - Object IDs

    func testObjectIDRoundTrip() {
        let refs = [
            PostgresObjectRef(kind: .schema, schema: "public", name: nil),
            PostgresObjectRef(kind: .table, schema: "sales.ops", name: "order\"line"),
            PostgresObjectRef(kind: .view, schema: "公共", name: "v_ü"),
        ]
        for ref in refs {
            let id = PostgresObjectIDCodec.encode(ref)
            XCTAssertTrue(id.hasPrefix("postgresql:"))
            XCTAssertEqual(PostgresObjectIDCodec.decode(id), ref)
        }
    }

    func testObjectIDMatchesElectronEncoding() throws {
        // The Electron adapter encodes JSON.stringify([kind, schema, name ?? null]).
        let expectedJSON = #"["table","public","users"]"#
        let expectedBase64URL = Data(expectedJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        XCTAssertEqual(
            PostgresObjectIDCodec.encode(
                PostgresObjectRef(kind: .table, schema: "public", name: "users")),
            "postgresql:" + expectedBase64URL)
    }

    func testObjectIDRejectsGarbage() {
        XCTAssertNil(PostgresObjectIDCodec.decode("mysql:AAAA"))
        XCTAssertNil(PostgresObjectIDCodec.decode("postgresql:!!!"))
        XCTAssertNil(PostgresObjectIDCodec.decode("postgresql:"))
        // Non-schema kinds require a name.
        let noName = PostgresObjectIDCodec.encode(
            PostgresObjectRef(kind: .table, schema: "public", name: nil))
        XCTAssertNil(PostgresObjectIDCodec.decode(noName))
    }
}
