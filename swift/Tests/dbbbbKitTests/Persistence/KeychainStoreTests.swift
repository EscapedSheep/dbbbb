import Foundation
import XCTest
@testable import dbbbbKit

final class KeychainStoreTests: XCTestCase {
    func testRemoveFailureHasDedicatedErrorAndMessage() {
        XCTAssertEqual(
            KeychainStoreError.removeFailed.userMessage,
            "The credential could not be removed from the Keychain.")
        XCTAssertNotEqual(
            KeychainStoreError.removeFailed.userMessage,
            KeychainStoreError.writeFailed.userMessage)
    }

    private struct FailingRemoveKeychainStore: KeychainStore {
        func secret(for id: UUID) throws -> String? { nil }
        func setSecret(_ secret: String, for id: UUID) throws {}
        func removeSecret(for id: UUID) throws { throw KeychainStoreError.removeFailed }
    }

    /// A Keychain removal failure surfaces to the caller as removeFailed.
    func testRemoveFailurePropagatesThroughConnectionStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-keychain-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directory: directory, keychain: FailingRemoveKeychainStore())
        XCTAssertThrowsError(try store.remove(id: UUID())) { error in
            XCTAssertEqual(error as? KeychainStoreError, .removeFailed)
        }
    }

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
