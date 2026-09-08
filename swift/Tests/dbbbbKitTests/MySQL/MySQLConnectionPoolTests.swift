import XCTest
import Foundation
import Darwin
import dbbbbCore
@testable import dbbbbKit
import NIOSSL
import NIO
import Logging

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

    /// Regression: the connect watchdog must actually return, not merely
    /// cancel the task — a server that completes the TCP handshake but never
    /// speaks MySQL used to hang the Add sheet indefinitely, because the
    /// pending NIO future ignores task cancellation.
    func testConnectTimeoutReturnsAgainstSilentServer() async throws {
        // Kernel-accepted but never accepted()/answered: the TCP connect
        // succeeds, the MySQL handshake never arrives.
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        defer { close(listenFD) }
        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listenFD, 1), 0)
        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenFD, $0, &actualLength)
            }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))

        MySQLConnector.connectTimeout.withLock { $0 = .milliseconds(300) }
        defer { MySQLConnector.connectTimeout.withLock { $0 = .seconds(10) } }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let silent = MySQLConnectionConfiguration(
            host: "127.0.0.1", port: port, username: "root", password: "",
            database: "db", sslMode: .disable, readOnly: false)
        let start = ContinuousClock.now
        do {
            _ = try await MySQLConnector.connect(
                config: silent, session: .standard, on: group.next(),
                logger: Logger(label: "dbbbb.tests.mysql.silent"))
            XCTFail("a silent server must fail with connectTimedOut")
        } catch let error as MySQLAdapterError {
            XCTAssertEqual(error, .connectTimedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
        try? await group.shutdownGracefully()
    }
}
