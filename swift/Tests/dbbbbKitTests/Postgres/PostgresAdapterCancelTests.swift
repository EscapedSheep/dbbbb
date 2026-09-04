import XCTest
import Foundation
import dbbbbCore
@testable import dbbbbKit

final class PostgresAdapterCancelTests: XCTestCase {
    /// A cancel that arrives before execute must be pre-registered, not
    /// dropped: the query is refused before any connection attempt.
    func testCancelBeforeExecuteSkipsQuery() async throws {
        let adapter = try PostgresAdapter(input: ConnectionInput.PostgresInput(
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
            _ = try await adapter.execute(.sql("SELECT pg_sleep(30)"), options: options)
            XCTFail("a pre-registered cancel must stop the query before it runs")
        } catch let error as PostgresAdapterError {
            XCTAssertEqual(error.userMessage, "PostgreSQL query was cancelled.")
        }
    }
}
