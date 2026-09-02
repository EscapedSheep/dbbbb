import Foundation
import dbbbbCore
import MySQLNIO

/// Everything needed to open a MySQL connection, credentials included.
/// Never crosses into the UI; error messages pass through `MySQLErrorSanitizer`.
struct MySQLConnectionConfiguration: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String
    var database: String
    var sslMode: SSLMode
    var readOnly: Bool

    var tlsConfiguration: TLSConfiguration? {
        switch sslMode {
        case .disable:
            return nil
        case .require:
            // Encrypt without verifying the server certificate.
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return configuration
        case .verifyFull:
            return TLSConfiguration.makeClientConfiguration()
        }
    }
}

/// A pooled connection plus its server thread id (for `KILL QUERY`).
struct MySQLLease: Sendable {
    let connection: MySQLConnection
    let threadID: UInt64
}

/// Opens MySQL connections and prepares their sessions.
enum MySQLConnector {
    static let connectTimeout: Duration = .seconds(10)
    static let readOnlySessionSQL = "SET SESSION transaction_read_only = ON"

    /// What a fresh connection needs before it can serve queries.
    enum Session: Sendable {
        /// Pooled query connection: read-only guardrail (when configured) + thread id.
        case standard
        /// Out-of-pool connection used only to issue `KILL QUERY`.
        case kill
    }

    static func connect(
        config: MySQLConnectionConfiguration,
        session: Session,
        on eventLoop: any EventLoop,
        logger: Logger
    ) async throws -> MySQLConnection {
        let connection = try await withConnectTimeout {
            let address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
            return try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database,
                password: config.password.isEmpty ? nil : config.password,
                tlsConfiguration: config.tlsConfiguration,
                serverHostname: config.sslMode == .disable ? nil : config.host,
                logger: logger,
                on: eventLoop
            ).get()
        }

        do {
            if config.readOnly, session == .standard {
                // Server-side enforcement behind the client-side classifier.
                // A session that refuses read-only mode is destroyed by the caller.
                _ = try await connection.simpleQuery(readOnlySessionSQL).get()
            }
            return connection
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    static func threadID(of connection: MySQLConnection) async throws -> UInt64 {
        let rows = try await connection.simpleQuery("SELECT CONNECTION_ID() AS dbbbb_thread_id").get()
        guard let data = rows.first?.column("dbbbb_thread_id"),
              let value = data.int64 ?? data.string.flatMap(Int64.init),
              value > 0
        else {
            throw MySQLAdapterError.failure("MySQL returned an invalid connection thread id.")
        }
        return UInt64(value)
    }

    private static func withConnectTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let operationTask = Task { try await operation() }
        let watchdog = Task {
            try? await Task.sleep(for: connectTimeout)
            operationTask.cancel()
        }
        defer { watchdog.cancel() }
        do {
            return try await operationTask.value
        } catch is CancellationError {
            throw MySQLAdapterError.connectTimedOut
        }
    }
}

/// A small bounded pool of MySQL connections. MySQLNIO ships no pool, so this
/// actor hands out up to `limit` live connections and queues the rest.
/// Cancellation never waits on this pool: `KILL QUERY` runs on a dedicated
/// out-of-pool connection instead.
actor MySQLConnectionPool {
    private let config: MySQLConnectionConfiguration
    private let group: any EventLoopGroup
    private let logger: Logger
    private let limit: Int

    private var idle: [MySQLLease] = []
    private var live: [ObjectIdentifier: MySQLConnection] = [:]
    private var opening = 0
    private var waiters: [CheckedContinuation<MySQLLease, any Error>] = []
    private var closed = false

    init(
        config: MySQLConnectionConfiguration,
        group: any EventLoopGroup,
        logger: Logger,
        limit: Int = 4
    ) {
        self.config = config
        self.group = group
        self.logger = logger
        self.limit = limit
    }

    func checkout() async throws -> MySQLLease {
        while let lease = idle.popLast() {
            if !lease.connection.isClosed { return lease }
            live.removeValue(forKey: ObjectIdentifier(lease.connection))
        }
        if closed { throw AdapterError.sessionClosed }
        if live.count + opening < limit {
            opening += 1
            do {
                let lease = try await open()
                opening -= 1
                return lease
            } catch {
                opening -= 1
                pumpWaiters()
                throw error
            }
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    /// Returns a lease to the pool. A connection that failed its read-only
    /// session setup or hit a transport error is destroyed, never reused.
    func checkin(_ lease: MySQLLease, healthy: Bool) {
        let reusable = healthy && !closed && !lease.connection.isClosed
        if reusable {
            if !waiters.isEmpty {
                waiters.removeFirst().resume(returning: lease)
            } else {
                idle.append(lease)
            }
            return
        }
        live.removeValue(forKey: ObjectIdentifier(lease.connection))
        if !lease.connection.isClosed {
            let connection = lease.connection
            Task { try? await connection.close().get() }
        }
        pumpWaiters()
    }

    func close() async {
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: AdapterError.sessionClosed)
        }
        let connections = Array(live.values)
        live.removeAll()
        idle.removeAll()
        for connection in connections where !connection.isClosed {
            try? await connection.close().get()
        }
    }

    private func open() async throws -> MySQLLease {
        let connection = try await MySQLConnector.connect(
            config: config,
            session: .standard,
            on: group.next(),
            logger: logger
        )
        do {
            let threadID = try await MySQLConnector.threadID(of: connection)
            live[ObjectIdentifier(connection)] = connection
            return MySQLLease(connection: connection, threadID: threadID)
        } catch {
            try? await connection.close().get()
            throw error
        }
    }

    /// After capacity frees up, open fresh connections for queued waiters.
    private func pumpWaiters() {
        while !closed, !waiters.isEmpty, live.count + opening < limit {
            let waiter = waiters.removeFirst()
            opening += 1
            Task {
                do {
                    waiter.resume(returning: try await self.open())
                } catch {
                    waiter.resume(throwing: error)
                }
                self.finishOpening()
            }
        }
    }

    private func finishOpening() {
        opening -= 1
        pumpWaiters()
    }
}
