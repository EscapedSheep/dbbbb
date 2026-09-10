import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit

/// BullMQ connection persistence: password in the Keychain, host/port/db/
/// prefix/TLS in the credential-free manifest (the MongoDB precedent).
struct BullmqConnectionStoreTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-bullmq-store-test-\(UUID().uuidString)")
    }

    private func bullmqInput(password: String = "s3cret") -> ConnectionInput {
        .bullmq(.init(
            name: "Queues", host: "redis.internal", port: 6380,
            password: password, database: 3, tls: true, prefix: "jobs",
            environment: .production, readOnly: true))
    }

    @Test func roundTripKeepsPasswordInKeychainOnly() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = InMemoryKeychainStore()
        let id = UUID()
        let input = bullmqInput()

        try ConnectionStore(directory: directory, keychain: keychain)
            .save(PersistedConnection(id: id, input: input), secret: PersistedConnection.secret(for: input))

        let manifest = try String(
            contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!manifest.contains("s3cret"), "password must never reach the manifest")
        #expect(manifest.contains("redis.internal"))
        #expect(manifest.contains("jobs"))

        let reloaded = ConnectionStore(directory: directory, keychain: keychain)
        let record = try #require(reloaded.loadConnections().first)
        #expect(record.engine == .bullmq)
        #expect(record.host == "redis.internal")
        #expect(record.port == 6380)
        #expect(record.tls == true)
        #expect(record.prefix == "jobs")
        #expect(record.database == "3")
        #expect(record.environment == .production)
        #expect(record.readOnly)

        guard case .bullmq(let restored) = try record.makeInput(secret: reloaded.secret(for: id)) else {
            Issue.record("expected a bullmq input")
            return
        }
        #expect(restored.password == "s3cret")
        #expect(restored.database == 3)
        #expect(restored.prefix == "jobs")
        #expect(restored.tls)
    }

    @Test func emptyPasswordWritesNoKeychainSecret() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keychain = InMemoryKeychainStore()
        let id = UUID()
        let input = bullmqInput(password: "")

        #expect(PersistedConnection.secret(for: input) == nil)
        try ConnectionStore(directory: directory, keychain: keychain)
            .save(PersistedConnection(id: id, input: input), secret: PersistedConnection.secret(for: input))

        let reloaded = ConnectionStore(directory: directory, keychain: keychain)
        let record = try #require(reloaded.loadConnections().first)
        guard case .bullmq(let restored) = try record.makeInput(secret: try reloaded.secret(for: id)) else {
            Issue.record("expected a bullmq input")
            return
        }
        #expect(restored.password == "")
    }
}
