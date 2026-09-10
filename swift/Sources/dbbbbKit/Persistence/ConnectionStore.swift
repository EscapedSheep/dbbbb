import Foundation
import dbbbbCore

/// Errors from connection persistence. Messages are pre-redacted: no secrets,
/// no credential-bearing URIs, no local paths.
public enum PersistenceError: dbbbbError, Equatable {
    case corruptRecord
    case missingSecret

    public var userMessage: String {
        switch self {
        case .corruptRecord: "A saved connection record is invalid and was skipped."
        case .missingSecret: "The saved credential for this connection is missing from the Keychain."
        }
    }
}

/// Credential-free manifest record for one persisted connection. Secrets
/// (PostgreSQL/MySQL passwords, the MongoDB URI) never appear here; they live
/// in the Keychain, keyed by `id`.
public struct PersistedConnection: Codable, Sendable, Equatable {
    public var id: UUID
    public var engine: DatabaseEngine
    public var name: String
    public var database: String
    public var environment: ConnectionEnvironment
    public var readOnly: Bool
    // PostgreSQL / MySQL
    public var host: String?
    public var port: Int?
    public var username: String?
    public var sslMode: SSLMode?
    // MongoDB
    public var tls: Bool?
    // SQLite
    public var filePath: String?
    // BullMQ (host/port/tls are shared with the SQL engines above; the Redis
    // logical database index rides in `database` as its decimal text)
    public var prefix: String?

    public init(id: UUID, input: ConnectionInput) {
        self.id = id
        engine = input.engine
        name = input.name
        database = input.database
        environment = input.environment
        readOnly = input.readOnly
        switch input {
        case .postgres(let input):
            host = input.host; port = input.port; username = input.username; sslMode = input.sslMode
        case .mysql(let input):
            host = input.host; port = input.port; username = input.username; sslMode = input.sslMode
        case .mongo(let input):
            tls = input.tls
        case .sqlite(let input):
            filePath = input.filePath
        case .bullmq(let input):
            host = input.host; port = input.port; tls = input.tls
            prefix = input.prefix
        }
    }

    /// The secret that belongs in the Keychain for this input, if the engine has one.
    public static func secret(for input: ConnectionInput) -> String? {
        switch input {
        case .postgres(let input): input.password
        case .mysql(let input): input.password
        case .mongo(let input): input.uri
        case .sqlite: nil
        case .bullmq(let input): input.password.isEmpty ? nil : input.password
        }
    }

    /// Rebuilds a full connection input with the secret pulled from the Keychain.
    public func makeInput(secret: String?) throws -> ConnectionInput {
        switch engine {
        case .postgresql:
            guard let host, let port, let username, let sslMode else { throw PersistenceError.corruptRecord }
            return .postgres(.init(
                name: name, host: host, port: port, username: username,
                password: secret ?? "", database: database,
                sslMode: sslMode, environment: environment, readOnly: readOnly))
        case .mysql:
            guard let host, let port, let username, let sslMode else { throw PersistenceError.corruptRecord }
            return .mysql(.init(
                name: name, host: host, port: port, username: username,
                password: secret ?? "", database: database,
                sslMode: sslMode, environment: environment, readOnly: readOnly))
        case .mongodb:
            guard let tls else { throw PersistenceError.corruptRecord }
            // The URI embeds credentials; without it the connection cannot be restored.
            guard let secret else { throw PersistenceError.missingSecret }
            return .mongo(.init(
                name: name, uri: secret, database: database, tls: tls,
                environment: environment, readOnly: readOnly))
        case .sqlite:
            guard let filePath else { throw PersistenceError.corruptRecord }
            return .sqlite(.init(
                name: name, filePath: filePath,
                environment: environment, readOnly: readOnly))
        case .bullmq:
            guard let host, let port, let tls, let prefix, let db = Int(database) else {
                throw PersistenceError.corruptRecord
            }
            return .bullmq(.init(
                name: name, host: host, port: port, password: secret ?? "",
                database: db, tls: tls, prefix: prefix,
                environment: environment, readOnly: readOnly))
        }
    }
}

/// Persists non-demo connections as a credential-free JSON manifest at
/// `~/Library/Application Support/dbbbb/connections.json`; secrets go to the
/// Keychain via `KeychainStore`. A manifest from an unknown schema version is
/// left untouched: the store keeps working in memory and never overwrites the
/// user's file (same rule as the Electron vault).
public final class ConnectionStore: @unchecked Sendable {
    public static let fileVersion = 1

    private struct Manifest: Codable {
        var version: Int
        var connections: [PersistedConnection]
    }

    private let fileURL: URL
    private let keychain: any KeychainStore
    private let lock = NSLock()
    private var records: [PersistedConnection]
    /// False when the on-disk file uses a schema we do not understand — writes
    /// are then in-memory only so the user's file is never clobbered.
    private var writeEnabled: Bool

    public convenience init(keychain: any KeychainStore = SecurityKeychainStore()) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dbbbb", isDirectory: true)
        self.init(directory: directory, keychain: keychain)
    }

    public init(directory: URL, keychain: any KeychainStore) {
        fileURL = directory.appendingPathComponent("connections.json")
        self.keychain = keychain
        let loaded = Self.loadManifest(from: fileURL)
        records = loaded.records
        writeEnabled = loaded.writeEnabled
    }

    /// The persisted manifest records, in file order.
    public func loadConnections() -> [PersistedConnection] {
        lock.withLock { records }
    }

    /// Reads the Keychain secret for a connection (password or MongoDB URI).
    public func secret(for id: UUID) throws -> String? {
        try keychain.secret(for: id)
    }

    /// Saves the manifest record and, when the engine has one, the secret.
    /// The Keychain write happens first so a failure cannot leave a manifest
    /// entry without its credential.
    public func save(_ connection: PersistedConnection, secret: String?) throws {
        if let secret {
            try keychain.setSecret(secret, for: connection.id)
        }
        try lock.withLock {
            if let index = records.firstIndex(where: { $0.id == connection.id }) {
                records[index] = connection
            } else {
                records.append(connection)
            }
            try persistLocked()
        }
    }

    /// Removes the manifest entry and the Keychain secret.
    public func remove(id: UUID) throws {
        try lock.withLock {
            records.removeAll { $0.id == id }
            try persistLocked()
        }
        try keychain.removeSecret(for: id)
    }

    // MARK: Private

    private static func loadManifest(from fileURL: URL) -> (records: [PersistedConnection], writeEnabled: Bool) {
        struct VersionProbe: Codable { var version: Int? }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return ([], true)
        }
        // The version is checked before any record decoding: a file from a
        // schema we do not understand is never overwritten, no matter what
        // its records look like (Electron vault/library semantics).
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
           let version = probe.version, version != fileVersion {
            return ([], false)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            // Corrupt file (undecodable or missing version): quarantine it to
            // a `.corrupt-<timestamp>` backup first, then start empty and allow
            // rewriting. If the backup fails, never clobber the original.
            return ([], CorruptFileBackup.backup(fileURL))
        }
        var seen = Set<UUID>()
        return (manifest.connections.filter { seen.insert($0.id).inserted }, true)
    }

    private func persistLocked() throws {
        guard writeEnabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Manifest(version: Self.fileVersion, connections: records))
        try AtomicFileWriter.write(data, to: fileURL, securingDirectory: true)
    }
}
