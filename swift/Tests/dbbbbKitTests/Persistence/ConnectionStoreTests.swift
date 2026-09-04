import Foundation
import XCTest
import dbbbbCore
@testable import dbbbbKit

/// Connection persistence: manifest JSON + Keychain fake, real temp-directory files.
final class ConnectionStoreTests: XCTestCase {
    private var directory: URL!
    private var keychain: InMemoryKeychainStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-connections-test-\(UUID().uuidString)")
        keychain = InMemoryKeychainStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var manifestURL: URL { directory.appendingPathComponent("connections.json") }

    private func makeStore() -> ConnectionStore {
        ConnectionStore(directory: directory, keychain: keychain)
    }

    private func postgresInput(password: String = "s3cret") -> ConnectionInput {
        .postgres(.init(
            name: "Warehouse", host: "db.internal", port: 5433,
            username: "analyst", password: password, database: "warehouse",
            sslMode: .require, environment: .production, readOnly: true))
    }

    // MARK: - Round trip

    func testSaveAndLoadRoundTripPostgres() throws {
        let id = UUID()
        try makeStore().save(PersistedConnection(id: id, input: postgresInput()), secret: "s3cret")

        let reloaded = makeStore()
        let records = reloaded.loadConnections()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, id)
        XCTAssertEqual(records[0].engine, .postgresql)
        XCTAssertEqual(records[0].host, "db.internal")
        XCTAssertEqual(records[0].port, 5433)
        XCTAssertEqual(records[0].username, "analyst")
        XCTAssertEqual(records[0].environment, .production)
        XCTAssertTrue(records[0].readOnly)

        let secret = try reloaded.secret(for: id)
        XCTAssertEqual(secret, "s3cret")
        let input = try records[0].makeInput(secret: secret)
        guard case .postgres(let postgres) = input else { return XCTFail("expected postgres input") }
        XCTAssertEqual(postgres.password, "s3cret")
        XCTAssertEqual(postgres.database, "warehouse")
    }

    func testMongoURIOnlyLivesInKeychain() throws {
        let id = UUID()
        let uri = "mongodb://user:p4ss@mongo.internal:27017/analytics"
        let input = ConnectionInput.mongo(.init(
            name: "Events", uri: uri, database: "analytics",
            tls: true, environment: .staging, readOnly: false))
        try makeStore().save(PersistedConnection(id: id, input: input), secret: PersistedConnection.secret(for: input))

        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains(uri), "Mongo URI must never reach the manifest")
        XCTAssertFalse(manifest.contains("p4ss"), "credentials must never reach the manifest")
        XCTAssertTrue(manifest.contains("Events"))

        let record = try XCTUnwrap(makeStore().loadConnections().first)
        XCTAssertEqual(try XCTUnwrap(makeStore().secret(for: id)), uri)
        guard case .mongo(let mongo) = try record.makeInput(secret: try makeStore().secret(for: id)) else {
            return XCTFail("expected mongo input")
        }
        XCTAssertEqual(mongo.uri, uri)
        XCTAssertEqual(mongo.database, "analytics")
    }

    func testSQLiteNeedsNoSecret() throws {
        let id = UUID()
        let input = ConnectionInput.sqlite(.init(name: "Notes", filePath: "/tmp/notes.db"))
        try makeStore().save(PersistedConnection(id: id, input: input), secret: PersistedConnection.secret(for: input))

        let record = try XCTUnwrap(makeStore().loadConnections().first)
        guard case .sqlite(let sqlite) = try record.makeInput(secret: nil) else {
            return XCTFail("expected sqlite input")
        }
        XCTAssertEqual(sqlite.filePath, "/tmp/notes.db")
        XCTAssertNil(try makeStore().secret(for: id), "no Keychain item should be written for SQLite")
    }

    func testManifestContainsNoPassword() throws {
        try makeStore().save(
            PersistedConnection(id: UUID(), input: postgresInput(password: "hunter2")),
            secret: "hunter2")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertFalse(manifest.contains("hunter2"))
        XCTAssertFalse(manifest.contains("password"), "the manifest has no password field at all")
    }

    func testSaveUpdatesExistingRecordInPlace() throws {
        let id = UUID()
        let store = makeStore()
        try store.save(PersistedConnection(id: id, input: postgresInput()), secret: "one")
        var updated = PersistedConnection(id: id, input: postgresInput())
        updated.name = "Renamed"
        try store.save(updated, secret: "two")

        let records = makeStore().loadConnections()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "Renamed")
        XCTAssertEqual(try makeStore().secret(for: id), "two")
    }

    // MARK: - Removal

    func testRemoveDeletesManifestEntryAndSecret() throws {
        let id = UUID()
        let store = makeStore()
        try store.save(PersistedConnection(id: id, input: postgresInput()), secret: "s3cret")
        try store.remove(id: id)

        XCTAssertTrue(makeStore().loadConnections().isEmpty)
        XCTAssertNil(try makeStore().secret(for: id))
    }

    // MARK: - Schema handling

    func testVersionMismatchKeepsFileUntouched() throws {
        let foreign = #"{"version": 999, "connections": [{"id": "x"}]}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try foreign.write(to: manifestURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.loadConnections().isEmpty)
        // Saving must not clobber a file whose schema we do not understand.
        try store.save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        XCTAssertEqual(try String(contentsOf: manifestURL, encoding: .utf8), foreign)
        XCTAssertTrue(try corruptBackups().isEmpty, "a foreign-version file is never renamed")
    }

    func testCorruptFileIsBackedUpThenRewritable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json at all".write(to: manifestURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.loadConnections().isEmpty)
        // The corrupt original is quarantined before any rewrite, never lost.
        let backups = try corruptBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), "not json at all")

        try store.save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        XCTAssertEqual(makeStore().loadConnections().count, 1)
        XCTAssertEqual(try corruptBackups().count, 1, "the backup survives the rewrite")
    }

    func testMissingVersionKeyIsBackedUpThenRewritable() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"connections": []}"#.write(to: manifestURL, atomically: false, encoding: .utf8)

        let store = makeStore()
        XCTAssertTrue(store.loadConnections().isEmpty)
        XCTAssertEqual(try corruptBackups().count, 1)
        try store.save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        XCTAssertEqual(makeStore().loadConnections().count, 1)
    }

    /// Fail-closed: when the corrupt file cannot be moved aside (directory not
    /// writable), the store must leave it alone instead of clobbering it.
    func testUnbackuppableCorruptFileIsNeverClobbered() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json at all".write(to: manifestURL, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        let store = makeStore()
        XCTAssertTrue(store.loadConnections().isEmpty)
        try store.save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        XCTAssertEqual(try String(contentsOf: manifestURL, encoding: .utf8), "not json at all")
        XCTAssertTrue(try corruptBackups().isEmpty)
    }

    private func corruptBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("connections.json.corrupt-") }
            .map { directory.appendingPathComponent($0) }
    }

    func testDuplicateIDsAreDroppedOnLoad() throws {
        let id = UUID()
        let store = makeStore()
        try store.save(PersistedConnection(id: id, input: postgresInput()), secret: "one")

        // Hand-craft a file with the same id twice.
        var recordA = PersistedConnection(id: id, input: postgresInput())
        recordA.name = "First"
        var recordB = PersistedConnection(id: id, input: postgresInput())
        recordB.name = "Second"
        struct Manual: Codable { var version: Int; var connections: [PersistedConnection] }
        let data = try JSONEncoder().encode(Manual(version: 1, connections: [recordA, recordB]))
        try data.write(to: manifestURL)

        let records = makeStore().loadConnections()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].name, "First")
    }

    // MARK: - Rebuild validation

    func testMongoWithoutSecretThrowsMissingSecret() {
        let input = ConnectionInput.mongo(.init(name: "m", uri: "mongodb://h/db", database: "db"))
        let record = PersistedConnection(id: UUID(), input: input)
        XCTAssertThrowsError(try record.makeInput(secret: nil)) { error in
            XCTAssertEqual(error as? PersistenceError, .missingSecret)
        }
    }

    func testMissingFieldsThrowCorruptRecord() {
        var record = PersistedConnection(id: UUID(), input: postgresInput())
        record.host = nil
        XCTAssertThrowsError(try record.makeInput(secret: "x")) { error in
            XCTAssertEqual(error as? PersistenceError, .corruptRecord)
        }
    }

    func testFilePermissionsAre0600() throws {
        try makeStore().save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    func testPreExistingDirectoryIsTightenedTo0700() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try makeStore().save(PersistedConnection(id: UUID(), input: postgresInput()), secret: "s3cret")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }
}
