import Foundation
import dbbbbCore
import PostgresNIO

/// PostgreSQL adapter built on PostgresNIO. One adapter owns one live session:
/// a small connection pool (default size 4) on its own event loop group.
///
/// Cancellation mirrors the Electron adapter: request IDs can be
/// pre-registered as cancelled, an out-of-pool dedicated connection issues
/// `pg_cancel_backend($1)` against the tracked backend PID, and a per-request
/// timeout timer dispatches cancellation as a second safety net.
public actor PostgresAdapter: DatabaseAdapter {
    public nonisolated let profile: ConnectionProfile

    private let input: ConnectionInput.PostgresInput
    private let tls: PostgresConnection.Configuration.TLS
    private let group: MultiThreadedEventLoopGroup
    private let logger = Logger(label: "app.dbbbb.postgres")
    private let maxConnections = 4

    private var idleConnections: [PostgresConnection] = []
    private var liveConnectionCount = 0
    private var waiters: [CheckedContinuation<PostgresConnection, any Error>] = []

    private var objects: [String: PostgresObjectRef] = [:]
    private var activeRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []
    private var timedOutRequestIDs: Set<UUID> = []
    private var backendPIDs: [UUID: Int32] = [:]

    private var sessionTimeZone: TimeZone?
    private var closed = false
    private var connectionIDCounter = 0

    public init(input: ConnectionInput.PostgresInput) throws {
        guard !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(input.port),
              !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PostgresAdapterError(message: "PostgreSQL connection settings are invalid.")
        }
        self.input = input
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .postgresql,
            endpoint: "\(input.host):\(input.port)",
            database: input.database,
            environment: input.environment,
            readOnly: input.readOnly)
        self.tls = try Self.makeTLS(for: input)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    // MARK: - Configuration

    private static func makeTLS(
        for input: ConnectionInput.PostgresInput
    ) throws -> PostgresConnection.Configuration.TLS {
        switch input.sslMode {
        case .disable:
            return .disable
        case .require:
            // Encrypted, but without certificate verification (node's
            // `rejectUnauthorized: false`).
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .none
            return .require(try NIOSSLContext(configuration: configuration))
        case .verifyFull:
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification = .fullVerification
            return .require(try NIOSSLContext(configuration: configuration))
        }
    }

    private func makeConfiguration() -> PostgresConnection.Configuration {
        var configuration = PostgresConnection.Configuration(
            host: input.host,
            port: input.port,
            username: input.username,
            password: input.password,
            database: input.database,
            tls: tls)
        configuration.options.connectTimeout = .seconds(10)
        configuration.options.tlsServerName = input.sslMode == .verifyFull ? input.host : nil
        configuration.options.additionalStartupParameters = [("application_name", "dbbbb")]
        return configuration
    }

    /// A raw connection without session setup — used for out-of-pool
    /// cancellation clients.
    private func openConnection() async throws -> PostgresConnection {
        connectionIDCounter += 1
        return try await PostgresConnection.connect(
            on: group.next(),
            configuration: makeConfiguration(),
            id: connectionIDCounter,
            logger: logger)
    }

    /// A pool connection: read-only sessions get the server-side guardrail,
    /// and the session time zone is captured once for timestamptz rendering.
    private func makePooledConnection() async throws -> PostgresConnection {
        let connection = try await openConnection()
        do {
            if input.readOnly {
                _ = try await connection.query(
                    "SET SESSION default_transaction_read_only = on", logger: logger)
            }
            if sessionTimeZone == nil {
                let rows = try await connection.query("SHOW TimeZone", logger: logger).collect()
                if let name = try rows.first?.decode(String.self) {
                    sessionTimeZone = TimeZone(identifier: name) ?? TimeZone(abbreviation: name)
                }
            }
            return connection
        } catch {
            try? await connection.close()
            throw error
        }
    }

    // MARK: - Pool

    private func checkOpen() throws {
        if closed { throw AdapterError.sessionClosed }
    }

    private func acquireConnection() async throws -> PostgresConnection {
        try checkOpen()
        while let candidate = idleConnections.popLast() {
            if !candidate.isClosed { return candidate }
            liveConnectionCount -= 1
        }
        if liveConnectionCount < maxConnections {
            liveConnectionCount += 1
            do {
                return try await makePooledConnection()
            } catch {
                liveConnectionCount -= 1
                throw error
            }
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PostgresConnection, any Error>) in
            if closed {
                continuation.resume(throwing: AdapterError.sessionClosed)
            } else {
                waiters.append(continuation)
            }
        }
    }

    private func releaseConnection(_ connection: PostgresConnection, destroy: Bool = false) {
        guard !closed, !destroy, !connection.isClosed else {
            liveConnectionCount -= 1
            if !connection.isClosed {
                Task { try? await connection.close() }
            }
            // The freed capacity can satisfy a queued waiter with a fresh connection.
            if !closed, !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                liveConnectionCount += 1
                Task {
                    do {
                        waiter.resume(returning: try await makePooledConnection())
                    } catch {
                        liveConnectionCount -= 1
                        waiter.resume(throwing: error)
                    }
                }
            }
            return
        }
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: connection)
        } else {
            idleConnections.append(connection)
        }
    }

    private func releaseAfterError(_ connection: PostgresConnection, _ error: any Error) {
        releaseConnection(connection, destroy: Self.isConnectionFailure(error))
    }

    // MARK: - Introspection

    /// Catalog tree query (the Electron adapter's query, with `relkind` cast
    /// to text so it decodes as a plain string).
    private static let listObjectsSQL: PostgresQuery = """
        SELECT n.nspname, c.relname, c.relkind::text
        FROM pg_catalog.pg_namespace AS n
        LEFT JOIN pg_catalog.pg_class AS c
          ON c.relnamespace = n.oid
         AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
        WHERE n.nspname <> 'information_schema'
          AND n.nspname !~ '^pg_'
          AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
        ORDER BY n.nspname, c.relname
        """

    public func listObjects() async throws -> [DatabaseObject] {
        try checkOpen()
        let connection = try await acquireConnection()
        do {
            let rows = try await connection.query(Self.listObjectsSQL, logger: logger).collect()
            releaseConnection(connection)

            var schemaOrder: [String] = []
            var bySchema: [String: [PostgresObjectRef]] = [:]
            for row in rows {
                let (schema, name, relationKind) = try row.decode((String, String?, String?).self)
                if bySchema[schema] == nil {
                    bySchema[schema] = []
                    schemaOrder.append(schema)
                }
                if name == nil && relationKind == nil { continue }
                guard let name, let relationKind else {
                    throw PostgresAdapterError(
                        message: "PostgreSQL returned invalid object metadata.")
                }
                let kind: PostgresObjectRef.Kind
                switch relationKind {
                case "r", "p", "f": kind = .table
                case "v", "m": kind = .view
                default:
                    throw PostgresAdapterError(
                        message: "PostgreSQL returned invalid object metadata.")
                }
                bySchema[schema]?.append(PostgresObjectRef(kind: kind, schema: schema, name: name))
            }

            var nodes: [DatabaseObject] = []
            var nextObjects: [String: PostgresObjectRef] = [:]
            for schema in schemaOrder {
                let schemaRef = PostgresObjectRef(kind: .schema, schema: schema, name: nil)
                let schemaID = PostgresObjectIDCodec.encode(schemaRef)
                nextObjects[schemaID] = schemaRef
                nodes.append(DatabaseObject(
                    id: schemaID, parentID: nil, name: schema, kind: .schema))
                for child in bySchema[schema] ?? [] {
                    let id = PostgresObjectIDCodec.encode(child)
                    nextObjects[id] = child
                    nodes.append(DatabaseObject(
                        id: id,
                        parentID: schemaID,
                        name: child.name ?? schema,
                        kind: child.kind == .table ? .table : .view))
                }
            }
            objects = nextObjects
            return nodes
        } catch let error as PostgresAdapterError {
            releaseConnection(connection, destroy: connection.isClosed)
            throw error
        } catch {
            releaseAfterError(connection, error)
            throw PostgresErrorSanitizer.sanitized(
                action: "Could not list PostgreSQL objects",
                error: error,
                secrets: [input.password])
        }
    }

    public func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        try checkOpen()
        guard let ref = objects[object.id] ?? PostgresObjectIDCodec.decode(object.id),
              ref.kind != .schema,
              let name = ref.name
        else {
            throw AdapterError.notFound("This PostgreSQL object cannot be previewed.")
        }
        let sql = """
            SELECT *
            FROM \(try PostgresChangePlanner.quoteIdentifier(ref.schema)).\(try PostgresChangePlanner.quoteIdentifier(name))
            LIMIT 100;
            """
        return try await execute(.sql(sql), options: ExecuteOptions())
    }

    // MARK: - Execute

    /// Marker for cancellation detected at an internal checkpoint.
    private struct QueryCancelled: Error {}

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        try checkOpen()
        guard case .sql(let sql) = command else { throw AdapterError.engineMismatch }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostgresAdapterError(message: "PostgreSQL query cannot be empty.")
        }
        if input.readOnly || profile.readOnly {
            try PostgresReadOnlyClassifier.assertReadOnly(sql)
        }
        guard options.maxRows >= 1, options.maxBytes >= 1, options.timeout >= .zero else {
            throw PostgresAdapterError(message: "PostgreSQL execution options are invalid.")
        }
        guard !activeRequestIDs.contains(options.requestID) else {
            throw PostgresAdapterError(
                message: "A PostgreSQL query with this request id is already running.")
        }
        activeRequestIDs.insert(options.requestID)

        let startedAt = Date()
        var connection: PostgresConnection?
        var destroyConnection = false
        var timeoutTask: Task<Void, Never>?

        defer {
            timeoutTask?.cancel()
            activeRequestIDs.remove(options.requestID)
            cancelledRequestIDs.remove(options.requestID)
            timedOutRequestIDs.remove(options.requestID)
            backendPIDs.removeValue(forKey: options.requestID)
            if let connection {
                releaseConnection(connection, destroy: destroyConnection || connection.isClosed)
            }
        }

        do {
            if cancelledRequestIDs.contains(options.requestID) { throw QueryCancelled() }
            let acquired = try await acquireConnection()
            connection = acquired
            if cancelledRequestIDs.contains(options.requestID) { throw QueryCancelled() }

            let pidRows = try await acquired.query(
                "SELECT pg_catalog.pg_backend_pid()", logger: logger).collect()
            guard let backendPID = try pidRows.first?.decode(Int32.self), backendPID > 0 else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned an invalid backend process id.")
            }
            backendPIDs[options.requestID] = backendPID
            if cancelledRequestIDs.contains(options.requestID) { throw QueryCancelled() }

            if options.timeout > .zero {
                timeoutTask = Task {
                    try? await Task.sleep(for: options.timeout)
                    guard !Task.isCancelled else { return }
                    self.markTimedOut(options.requestID)
                }
            }

            let sequence = try await acquired.query(PostgresQuery(unsafeSQL: sql), logger: logger)
            let columns = PostgresWireCodec.columnMetas(
                sequence.columns.map { ($0.name, $0.dataType) })

            let timezoneOffset = sessionTimezoneOffset()

            var rawRows: [[DisplayValue]] = []
            for try await row in sequence {
                rawRows.append(row.map { cell in
                    PostgresWireCodec.displayValue(
                        type: cell.dataType,
                        bytes: cell.bytes.map { Array($0.readableBytesView) },
                        timezoneOffsetSeconds: timezoneOffset)
                })
            }
            if cancelledRequestIDs.contains(options.requestID)
                || timedOutRequestIDs.contains(options.requestID) {
                throw QueryCancelled()
            }

            let bounded = PostgresWireCodec.boundRows(
                rawRows, maxRows: options.maxRows, maxBytes: options.maxBytes)
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            return .rows(
                columns: columns,
                rows: bounded.rows,
                meta: ResultMeta(
                    count: bounded.rows.count,
                    truncated: bounded.truncated,
                    elapsedMilliseconds: elapsed))
        } catch {
            destroyConnection = Self.isConnectionFailure(error)
            let wasCancelled = cancelledRequestIDs.contains(options.requestID)
            if wasCancelled || Self.isCancellationError(error) {
                let timedOut = timedOutRequestIDs.contains(options.requestID)
                    || (!wasCancelled && Self.isStatementTimeoutError(error))
                throw PostgresAdapterError(
                    message: timedOut
                        ? "PostgreSQL query timed out."
                        : "PostgreSQL query was cancelled.",
                    sqlState: "57014")
            }
            if let adapterError = error as? PostgresAdapterError {
                throw adapterError
            }
            throw PostgresErrorSanitizer.sanitized(
                action: "PostgreSQL query failed",
                error: error,
                secrets: [input.password])
        }
    }

    // MARK: - Cancel

    public func cancel(requestID: UUID) async throws {
        guard activeRequestIDs.contains(requestID) else { return }
        cancelledRequestIDs.insert(requestID)
        guard let backendPID = backendPIDs[requestID] else { return }
        do {
            try await dispatchCancel(backendPID: backendPID)
        } catch {
            throw PostgresErrorSanitizer.sanitized(
                action: "Could not cancel PostgreSQL query",
                error: error,
                secrets: [input.password])
        }
    }

    private func markTimedOut(_ requestID: UUID) {
        guard activeRequestIDs.contains(requestID) else { return }
        timedOutRequestIDs.insert(requestID)
        cancelledRequestIDs.insert(requestID)
        guard let backendPID = backendPIDs[requestID] else { return }
        Task { try? await self.dispatchCancel(backendPID: backendPID) }
    }

    /// Cancellation runs on a dedicated out-of-pool connection so it never
    /// queues behind a saturated pool.
    private func dispatchCancel(backendPID: Int32) async throws {
        let connection = try await openConnection()
        do {
            let rows = try await connection.query(
                "SELECT pg_catalog.pg_cancel_backend(\(backendPID))", logger: logger
            ).collect()
            try? await connection.close()
            guard try rows.first?.decode(Bool.self) == true else {
                throw PostgresAdapterError(
                    message: "PostgreSQL did not accept the cancellation request.")
            }
        } catch {
            try? await connection.close()
            throw error
        }
    }

    // MARK: - Close

    public func close() async {
        if closed { return }
        closed = true

        for requestID in activeRequestIDs { cancelledRequestIDs.insert(requestID) }
        let pids = Array(backendPIDs.values)
        await withTaskGroup(of: Void.self) { taskGroup in
            for pid in pids {
                taskGroup.addTask { try? await self.dispatchCancel(backendPID: pid) }
            }
        }

        let idle = idleConnections
        idleConnections = []
        liveConnectionCount -= idle.count
        for connection in idle {
            try? await connection.close()
        }

        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(throwing: AdapterError.sessionClosed)
        }

        objects = [:]
        try? await group.shutdownGracefully()
    }

    // MARK: - Error classification

    /// Errors whose connection must not return to the pool: SQLSTATE class 08
    /// (connection exception) and 57P0x (server shutdown/crash), plus
    /// driver-level connection failures.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let psqlError = error as? PSQLError else { return false }
        if let state = psqlError.serverInfo?[.sqlState] {
            return state.hasPrefix("08") || state.hasPrefix("57P0")
        }
        switch psqlError.code {
        case .serverClosedConnection, .clientClosedConnection, .connectionError,
             .uncleanShutdown, .sslUnsupported, .receivedUnencryptedDataAfterSSLRequest,
             .failedToAddSSLHandler:
            return true
        default:
            return false
        }
    }

    static func isCancellationError(_ error: any Error) -> Bool {
        guard let psqlError = error as? PSQLError else { return false }
        if psqlError.serverInfo?[.sqlState] == "57014" { return true }
        if let message = psqlError.serverInfo?[.message],
           message.range(
               of: #"cancel(?:ing|led) statement"#,
               options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    static func isStatementTimeoutError(_ error: any Error) -> Bool {
        PostgresErrorSanitizer.describe(error).localizedCaseInsensitiveContains("statement timeout")
    }
}

// MARK: - Editing

extension PostgresAdapter: SupportsEditing {
    /// Applies one reviewed single-row change inside a transaction: introspect
    /// + validate the change-target metadata, plan with the pure planner, and
    /// execute the parameterized statement. `RETURNING *` yields the changed
    /// row; zero rows means the row changed or vanished underneath the edit
    /// (optimistic-concurrency conflict). Read-only sessions are refused
    /// client-side here and server-side via `default_transaction_read_only`.
    public func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        try checkOpen()
        if input.readOnly || profile.readOnly {
            throw PostgresAdapterError(
                message: "PostgreSQL row changes are disabled for read-only connections.")
        }
        guard let ref = objects[change.object.id] ?? PostgresObjectIDCodec.decode(change.object.id),
              ref.kind == .table,
              let name = ref.name
        else {
            throw AdapterError.notFound("PostgreSQL row changes require an introspected table target.")
        }

        let startedAt = Date()
        let connection = try await acquireConnection()
        var inTransaction = false
        var destroyConnection = false
        defer {
            releaseConnection(connection, destroy: destroyConnection || connection.isClosed)
        }

        do {
            _ = try await connection.query("BEGIN", logger: logger)
            inTransaction = true

            var metadataBinds = PostgresBindings()
            metadataBinds.append(ref.schema)
            metadataBinds.append(name)
            let metadataSequence = try await connection.query(
                PostgresQuery(
                    unsafeSQL: PostgresChangePlanner.listTableChangeColumnsSQL,
                    binds: metadataBinds),
                logger: logger)
            let metadata = try await PostgresChangePlanner.changeTableMetadata(
                rows: Self.changeMetadataRows(from: metadataSequence))

            let original = try PostgresChangeMapper.orderedEntries(
                change.original, metadata: metadata, label: "PostgreSQL original values")
            let current: [PostgresFieldEntry]?
            switch change.operation {
            case .update(let changed):
                current = try PostgresChangeMapper.currentEntries(original: original, changed: changed)
            case .delete:
                current = nil
            }
            let primaryKey = try PostgresChangeMapper.primaryKeyEntries(
                metadata: metadata, original: original)

            let plan: PostgresParameterizedPlan
            if let current {
                plan = try PostgresChangePlanner.planUpdate(
                    schema: ref.schema, table: name,
                    primaryKey: primaryKey, original: original, current: current)
            } else {
                plan = try PostgresChangePlanner.planDelete(
                    schema: ref.schema, table: name,
                    primaryKey: primaryKey, original: original)
            }

            let bindColumns = PostgresChangeMapper.bindColumns(
                primaryKey: primaryKey, original: original, current: current)
            var binds = PostgresBindings()
            guard bindColumns.count == plan.values.count else {
                throw PostgresAdapterError(message: "PostgreSQL change planning failed.")
            }
            for (column, value) in zip(bindColumns, plan.values) {
                guard let typeOID = metadata.columnTypeOIDs[column] else {
                    throw PostgresAdapterError(message: "PostgreSQL change planning failed.")
                }
                guard let text = try PostgresChangeMapper.bindText(for: value, label: column) else {
                    binds.appendNull()
                    continue
                }
                try binds.append(PostgresTextParameter(
                    psqlType: PostgresDataType(UInt32(clamping: typeOID)), text: text))
            }

            let sequence = try await connection.query(
                PostgresQuery(unsafeSQL: plan.text, binds: binds), logger: logger)
            let (columns, rows) = try await decodeRows(from: sequence)
            guard !rows.isEmpty else {
                throw PostgresAdapterError(
                    message: "PostgreSQL optimistic-concurrency conflict: the row changed or no longer exists.")
            }
            guard rows.count == 1 else {
                throw PostgresAdapterError(
                    message: "PostgreSQL refused a row change with an unexpected affected-row count.")
            }

            _ = try await connection.query("COMMIT", logger: logger)
            inTransaction = false
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            return .rows(
                columns: columns,
                rows: rows,
                meta: ResultMeta(count: rows.count, truncated: false, elapsedMilliseconds: elapsed))
        } catch {
            if inTransaction {
                _ = try? await connection.query("ROLLBACK", logger: logger)
            }
            destroyConnection = Self.isConnectionFailure(error)
            if let planError = error as? PostgresChangePlanError { throw planError }
            if let adapterError = error as? PostgresAdapterError { throw adapterError }
            if let adapterError = error as? AdapterError { throw adapterError }
            throw PostgresErrorSanitizer.sanitized(
                action: "PostgreSQL data change failed",
                error: error,
                secrets: [input.password])
        }
    }

    /// Rows + column metadata for a finished change statement (`RETURNING *`),
    /// decoded with the same display semantics as `execute`.
    private func decodeRows(
        from sequence: PostgresRowSequence
    ) async throws -> ([ColumnMeta], [[DisplayValue]]) {
        let columns = PostgresWireCodec.columnMetas(
            sequence.columns.map { ($0.name, $0.dataType) })
        let timezoneOffset = sessionTimezoneOffset()
        var rows: [[DisplayValue]] = []
        for try await row in sequence {
            rows.append(row.map { cell in
                PostgresWireCodec.displayValue(
                    type: cell.dataType,
                    bytes: cell.bytes.map { Array($0.readableBytesView) },
                    timezoneOffsetSeconds: timezoneOffset)
            })
        }
        return (columns, rows)
    }

    /// Session-timezone UTC offset (seconds, positive east) for an instant in
    /// microseconds since 2000-01-01 UTC; zero when the zone is unknown.
    private func sessionTimezoneOffset() -> (Int64) -> Int {
        { [sessionTimeZone] microseconds in
            guard let sessionTimeZone else { return 0 }
            let seconds = microseconds.divideFloor(by: 1_000_000)
            return sessionTimeZone.secondsFromGMT(
                for: Date(timeIntervalSince1970: 946_684_800 + Double(seconds)))
        }
    }

    /// Decodes `(attname, atttypid, typname, primary_key_ordinal)` rows from
    /// the change-metadata introspection query. `atttypid` arrives as a binary
    /// OID, which PostgresNIO's typed decoders reject, so cells are read
    /// byte-wise.
    private static func changeMetadataRows(
        from sequence: PostgresRowSequence
    ) async throws -> [(name: String, typeOID: Int, typeName: String, primaryKeyOrdinal: Int)] {
        var rows: [(name: String, typeOID: Int, typeName: String, primaryKeyOrdinal: Int)] = []
        for try await row in sequence {
            let cells = row.map { $0 }
            guard cells.count == 4,
                  let name = text(cells[0]),
                  let typeOID = integer(cells[1], as: UInt32.self),
                  let typeName = text(cells[2]),
                  let ordinal = integer(cells[3], as: Int32.self)
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid table-change metadata.")
            }
            rows.append((name, Int(typeOID), typeName, Int(ordinal)))
        }
        return rows
    }

    private static func text(_ cell: PostgresCell) -> String? {
        cell.bytes.map { String(decoding: $0.readableBytesView, as: UTF8.self) }
    }

    private static func integer<T: FixedWidthInteger>(_ cell: PostgresCell, as type: T.Type) -> T? {
        guard let bytes = cell.bytes else { return nil }
        return PostgresWireCodec.readInt(Array(bytes.readableBytesView), as: type)
    }
}

// MARK: - Importing

extension PostgresAdapter: SupportsImporting {
    /// Insertable columns of the import target (name + type OID for the text
    /// binds), ported from the Electron `LIST_INSERTABLE_COLUMNS_SQL`: dropped,
    /// generated, and always-identity columns are excluded, and INSERT
    /// privilege is required per column.
    private static let listInsertableColumnsSQL = """
        SELECT a.attname, a.atttypid
        FROM pg_catalog.pg_attribute AS a
        JOIN pg_catalog.pg_class AS c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE n.nspname = $1
          AND c.relname = $2
          AND c.relkind IN ('r', 'p', 'f')
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND a.attgenerated = ''
          AND a.attidentity <> 'a'
          AND pg_catalog.has_column_privilege(c.oid, a.attname, 'INSERT')
        ORDER BY a.attnum
        """

    /// Streams a CSV file into one introspected table. Like the Electron
    /// adapter, the whole file runs in a single transaction and rolls back if
    /// any batch fails; every value crosses as a text bind with the column's
    /// catalog type OID, so the server parses it with the type's input
    /// function (its import-time type coercion).
    public func importData(_ request: ImportRequest) async throws -> ImportSummary {
        try checkOpen()
        if input.readOnly || profile.readOnly {
            throw ImportError.unsupported(
                "PostgreSQL import is disabled for read-only connections.")
        }
        guard request.format == .csv else {
            throw ImportError.unsupported("PostgreSQL imports accept CSV files.")
        }
        guard let ref = objects[request.target.id] ?? PostgresObjectIDCodec.decode(request.target.id),
              ref.kind == .table,
              let name = ref.name
        else {
            throw AdapterError.notFound("PostgreSQL import requires an introspected table target.")
        }

        let connection = try await acquireConnection()
        var inTransaction = false
        var destroyConnection = false
        defer {
            releaseConnection(connection, destroy: destroyConnection || connection.isClosed)
        }

        do {
            var metadataBinds = PostgresBindings()
            metadataBinds.append(ref.schema)
            metadataBinds.append(name)
            let metadataSequence = try await connection.query(
                PostgresQuery(unsafeSQL: Self.listInsertableColumnsSQL, binds: metadataBinds),
                logger: logger)
            let metadata = try await Self.insertableColumns(from: metadataSequence)
            let allowedColumns = Set(metadata.map(\.name))
            let typeOIDs = Dictionary(
                metadata.map { ($0.name, $0.typeOID) }) { first, _ in first }
            let batchSize = try PostgresImportPlanner.batchSize(columnCount: metadata.count)

            if request.isCancelled() { throw ImportError.cancelled }
            _ = try await connection.query("BEGIN", logger: logger)
            inTransaction = true

            let summary = try await CSVImportDriver.run(
                fileURL: request.fileURL,
                hasHeader: request.hasHeader,
                knownColumns: metadata.map(\.name),
                batchSize: batchSize,
                isCancelled: request.isCancelled,
                onProgress: request.onProgress,
                insertBatch: { targets, rows in
                    guard targets.allSatisfy(allowedColumns.contains) else {
                        throw PostgresChangePlanError(
                            reason: "PostgreSQL import batch contains an invalid column mapping.")
                    }
                    let sql = try PostgresImportPlanner.insertStatement(
                        schema: ref.schema, table: name, columns: targets, rowCount: rows.count)
                    var binds = PostgresBindings()
                    for row in rows {
                        guard row.count == targets.count else {
                            throw PostgresChangePlanError(
                                reason: "PostgreSQL import batch has inconsistent columns.")
                        }
                        for (column, value) in zip(targets, row) {
                            guard let typeOID = typeOIDs[column] else {
                                throw PostgresChangePlanError(
                                    reason: "PostgreSQL import batch contains an invalid column mapping.")
                            }
                            try binds.append(PostgresTextParameter(
                                psqlType: PostgresDataType(typeOID), text: value))
                        }
                    }
                    _ = try await connection.query(
                        PostgresQuery(unsafeSQL: sql, binds: binds), logger: logger)
                    return rows.count
                })

            if request.isCancelled() { throw ImportError.cancelled }
            _ = try await connection.query("COMMIT", logger: logger)
            inTransaction = false
            return summary
        } catch {
            if inTransaction {
                _ = try? await connection.query("ROLLBACK", logger: logger)
            }
            destroyConnection = Self.isConnectionFailure(error)
            if let importError = error as? ImportError { throw importError }
            if let planError = error as? PostgresChangePlanError { throw planError }
            if let adapterError = error as? AdapterError { throw adapterError }
            if let adapterError = error as? PostgresAdapterError { throw adapterError }
            throw PostgresErrorSanitizer.sanitized(
                action: "PostgreSQL import failed",
                error: error,
                secrets: [input.password])
        }
    }

    /// Decodes `(attname, atttypid)` introspection rows. `atttypid` arrives as
    /// a binary OID, which PostgresNIO's typed decoders reject, so cells are
    /// read byte-wise (same approach as the change-metadata decoder).
    private static func insertableColumns(
        from sequence: PostgresRowSequence
    ) async throws -> [(name: String, typeOID: UInt32)] {
        var columns: [(name: String, typeOID: UInt32)] = []
        var seen: Set<String> = []
        for try await row in sequence {
            let cells = row.map { $0 }
            guard cells.count == 2,
                  let nameBytes = cells[0].bytes,
                  let oidBytes = cells[1].bytes,
                  let typeOID = PostgresWireCodec.readInt(
                      Array(oidBytes.readableBytesView), as: UInt32.self),
                  typeOID > 0
            else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned invalid insertable-column metadata.")
            }
            let name = String(decoding: nameBytes.readableBytesView, as: UTF8.self)
            guard !name.isEmpty, seen.insert(name).inserted else {
                throw PostgresAdapterError(
                    message: "PostgreSQL returned duplicate insertable-column metadata.")
            }
            columns.append((name, typeOID))
        }
        guard !columns.isEmpty else {
            throw PostgresAdapterError(
                message: "PostgreSQL import target has no insertable columns.")
        }
        return columns
    }
}
