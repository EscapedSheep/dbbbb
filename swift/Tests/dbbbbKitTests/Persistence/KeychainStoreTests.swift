import Foundation
import XCTest
@testable import dbbbbKit

final class KeychainStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrip() throws {
        let store = InMemoryKeychainStore()
        let id = UUID()
        XCTAssertNil(try store.secret(for: id))
        try store.setSecret("secret", for: id)
        XCTAssertEqual(try store.secret(for: id), "secret")
        try store.setSecret("updated", for: id)
        XCTAssertEqual(try store.secret(for: id), "updated")
        try store.removeSecret(for: id)
        XCTAssertNil(try store.secret(for: id))
        // Removing a missing item is not an error.
        try store.removeSecret(for: id)
    }

    /// One real-Keychain round trip against a dedicated service name. If the
    /// environment denies Keychain access (sandbox, headless CI) the test is
    /// skipped rather than failed.
    func testSecurityKeychainStoreRoundTrip() throws {
        let service = "dev.dbbbb.connection.test.\(UUID().uuidString)"
        let store = SecurityKeychainStore(service: service)
        let id = UUID()
        do {
            try store.setSecret("keychain-round-trip", for: id)
        } catch {
            throw XCTSkip("Keychain unavailable in this environment: \(error.localizedDescription)")
        }
        defer { try? store.removeSecret(for: id) }

        XCTAssertEqual(try store.secret(for: id), "keychain-round-trip")
        try store.setSecret("updated", for: id)
        XCTAssertEqual(try store.secret(for: id), "updated")
        try store.removeSecret(for: id)
        XCTAssertNil(try store.secret(for: id))
    }
}
