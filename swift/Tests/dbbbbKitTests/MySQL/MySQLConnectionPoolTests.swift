import XCTest
import Foundation
import dbbbbCore
@testable import dbbbbKit
import NIOSSL

final class MySQLConnectionPoolTests: XCTestCase {
    private func config(sslMode: SSLMode) -> MySQLConnectionConfiguration {
        MySQLConnectionConfiguration(
            host: "db-server.internal",
            port: 3306,
            username: "root",
            password: "top-secret-password",
            database: "db",
            sslMode: sslMode,
            readOnly: false
        )
    }

    func testTLSConfigurationMapping() throws {
        XCTAssertNil(config(sslMode: .disable).tlsConfiguration)
        // require: encrypted, but no certificate verification.
        let requireTLS = try XCTUnwrap(config(sslMode: .require).tlsConfiguration)
        guard case .none = requireTLS.certificateVerification else {
            return XCTFail("require must encrypt without certificate verification")
        }
        XCTAssertEqual(
            config(sslMode: .verifyFull).tlsConfiguration?.certificateVerification,
            .fullVerification)
    }

    /// The fail-closed TLS error must stay free of hostnames and credentials.
    func testTLSRequiredErrorIsSanitized() {
        let message = MySQLAdapterError.tlsRequired.userMessage
        XCTAssertTrue(message.contains("TLS"))
        XCTAssertFalse(message.contains("db-server.internal"))
        XCTAssertFalse(message.contains("top-secret-password"))
    }

    /// A cancel that arrives before execute must be pre-registered, not
    /// dropped: the query is refused before any connection attempt.
    func testCancelBeforeExecuteSkipsQuery() async throws {
        let adapter = try MySQLAdapter(input: ConnectionInput.MySQLInput(
            name: "unreachable",
            host: "127.0.0.1",
            port: 1,
            username: "root",
            password: "",
            database: "db",
            sslMode: .disable
        ))
        addTeardownBlock {
            await adapter.close()
        }
        let options = ExecuteOptions(timeout: .milliseconds(50))
        try await adapter.cancel(requestID: options.requestID)
        do {
            _ = try await adapter.execute(.sql("SELECT SLEEP(30)"), options: options)
            XCTFail("a pre-registered cancel must stop the query before it runs")
        } catch let error as MySQLAdapterError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    /// Actor-level lifecycle: unknown ids are pre-registered, and finish
    /// clears the registration again.
    func testAdapterStateCancelPreRegistrationLifecycle() async throws {
        let state = MySQLAdapterState()
        let requestID = UUID()
        let threadID = await state.cancel(requestID: requestID)
        XCTAssertNil(threadID)
        let registered = await state.isCancelled(requestID)
        XCTAssertTrue(registered)

        try await state.begin(requestID: requestID)
        let outcome = await state.finish(requestID: requestID)
        XCTAssertTrue(outcome.cancelled)
        let cleared = await state.isCancelled(requestID)
        XCTAssertFalse(cleared)
    }
}
