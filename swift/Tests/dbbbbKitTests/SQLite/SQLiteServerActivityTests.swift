import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// SQLite is file-local: no server processes exist to list or kill, so the
/// adapter fails closed by not conforming to `SupportsServerActivity`
/// (ROADMAP M2 ⑨).
final class SQLiteServerActivityTests: XCTestCase {
    func testSQLiteDoesNotConformToServerActivity() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-sqlite-activity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let adapter = try SQLiteAdapter(input: .init(name: "t", filePath: url.path))
        defer {
            Task { await adapter.close() }
        }
        XCTAssertFalse(adapter is any SupportsServerActivity)
    }
}
