import Foundation
import dbbbbCore
import MySQLNIO

/// Internal handle for a navigator object, encoded into `DatabaseObject.id`.
struct MySQLObjectRef: Sendable, Equatable {
    enum Kind: String, Sendable {
        case database, table, view
    }

    let kind: Kind
    let database: String
    let name: String?

    /// Opaque, stable id: base64 JSON, same shape as the Electron adapter.
    var id: String {
        let payload: [Any] = [kind.rawValue, database, name ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return "mysql:\(kind.rawValue)"
        }
        return "mysql:\(data.base64EncodedString())"
    }
}

/// Adapter-owned mutable state: executions, cancellation pre-registration,
/// the object cache, and the closed flag. One actor keeps it all Sendable-safe.
actor MySQLAdapterState {
    struct Execution: Sendable {
        var threadID: UInt64?
        var timedOut = false
    }

    private var executions: [UUID: Execution] = [:]
    private var cancelledRequestIDs: Set<UUID> = []
    private var objectRefs: [String: MySQLObjectRef] = [:]
    private(set) var closed = false

    func begin(requestID: UUID) throws {
        guard executions[requestID] == nil else {
            throw MySQLAdapterError.duplicateRequestID
        }
        executions[requestID] = Execution()
    }

    func isCancelled(_ requestID: UUID) -> Bool {
        cancelledRequestIDs.contains(requestID)
    }

    func activate(requestID: UUID, threadID: UInt64) {
        executions[requestID]?.threadID = threadID
    }

    /// Pre-registers cancellation. Returns the thread id to kill when the query
    /// is already running; otherwise the next cancellation checkpoint catches it.
    func cancel(requestID: UUID) -> UInt64? {
        guard let execution = executions[requestID] else { return nil }
        cancelledRequestIDs.insert(requestID)
        return execution.threadID
    }

    /// Marks the request timed out; returns the thread id to kill if running.
    func timeout(requestID: UUID) -> UInt64? {
        guard var execution = executions[requestID] else { return nil }
        execution.timedOut = true
        executions[requestID] = execution
        return execution.threadID
    }

    /// Clears the request and reports how it ended, for error mapping.
    func finish(requestID: UUID) -> (cancelled: Bool, timedOut: Bool) {
        let execution = executions.removeValue(forKey: requestID)
        let cancelled = cancelledRequestIDs.remove(requestID) != nil
        return (cancelled, execution?.timedOut ?? false)
    }

    /// Pre-registers cancellation for every in-flight request and returns the
    /// thread ids worth killing.
    func cancelAll() -> [UInt64] {
        var threadIDs: [UInt64] = []
        for (requestID, execution) in executions {
            cancelledRequestIDs.insert(requestID)
            if let threadID = execution.threadID {
                threadIDs.append(threadID)
            }
        }
        return threadIDs
    }

    /// Returns true when the adapter was already closed.
    func markClosed() -> Bool {
        let wasClosed = closed
        closed = true
        return wasClosed
    }

    func setObjects(_ refs: [String: MySQLObjectRef]) {
        objectRefs = refs
    }

    func objectRef(for id: String) -> MySQLObjectRef? {
        objectRefs[id]
    }
}

/// MySQL adapter on MySQLNIO. Read-only profiles are enforced twice: the
/// client-side classifier (`MySQLReadOnlyClassifier`) and a per-session
/// `SET SESSION transaction_read_only = ON` server guardrail.
public final class MySQLAdapter: DatabaseAdapter {
    public let profile: ConnectionProfile

    private let input: ConnectionInput.MySQLInput
    private let config: MySQLConnectionConfiguration
    private let group: MultiThreadedEventLoopGroup
    private let pool: MySQLConnectionPool
    private let state = MySQLAdapterState()
    private let logger = Logger(label: "dev.dbbbb.mysql")

    private static let listObjectsSQL = """
        SELECT TABLE_NAME, TABLE_TYPE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = ?
        ORDER BY TABLE_NAME
        """

    private static let previewLimit = 100

    public init(input: ConnectionInput.MySQLInput) throws {
        guard !input.host.trimmingCharacters(in: .whitespaces).isEmpty,
              (1...65535).contains(input.port),
              !input.username.trimmingCharacters(in: .whitespaces).isEmpty,
              !input.database.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw MySQLAdapterError.invalidConfiguration
        }
        self.input = input
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .mysql,
            endpoint: "\(input.host):\(input.port)",
            database: input.database,
            environment: input.environment,
            readOnly: input.readOnly
        )
        self.config = MySQLConnectionConfiguration(
            host: input.host,
            port: input.port,
            username: input.username,
            password: input.password,
            database: input.database,
            sslMode: input.sslMode,
            readOnly: input.readOnly
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        self.pool = MySQLConnectionPool(config: config, group: group, logger: logger)
    }

    // MARK: - DatabaseAdapter

    public func listObjects() async throws -> [DatabaseObject] {
        try await ensureOpen()
        let rows: [MySQLRow]
        do {
            rows = try await withLease { lease in
                try await lease.connection
                    .query(Self.listObjectsSQL, [MySQLData(string: self.input.database)])
                    .get()
            }
        } catch {
            throw sanitized("Could not list MySQL objects", error)
        }

        var refs: [MySQLObjectRef] = []
        for row in rows {
            guard let name = row.column("TABLE_NAME")?.string, !name.isEmpty,
                  let type = row.column("TABLE_TYPE")?.string
            else {
                throw MySQLAdapterError.failure("Could not list MySQL objects: invalid object metadata.")
            }
            let kind: MySQLObjectRef.Kind? =
                type == "BASE TABLE" ? .table :
                type == "VIEW" ? .view : nil
            if let kind {
                refs.append(MySQLObjectRef(kind: kind, database: input.database, name: name))
            }
        }

        let databaseRef = MySQLObjectRef(kind: .database, database: input.database, name: nil)
        var objects = [DatabaseObject(
            id: databaseRef.id,
            parentID: nil,
            name: input.database,
            kind: .database
        )]
        var cache: [String: MySQLObjectRef] = [databaseRef.id: databaseRef]
        for ref in refs {
            cache[ref.id] = ref
            objects.append(DatabaseObject(
                id: ref.id,
                parentID: databaseRef.id,
                name: ref.name ?? "",
                kind: ref.kind == .view ? .view : .table
            ))
        }
        await state.setObjects(cache)
        return objects
    }

    public func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id),
              ref.kind != .database,
              let name = ref.name
        else {
            throw AdapterError.notFound("This MySQL object cannot be previewed.")
        }
        let sql = """
            SELECT *
            FROM \(Self.quoteIdentifier(ref.database)).\(Self.quoteIdentifier(name))
            LIMIT \(Self.previewLimit)
            """
        return try await execute(.sql(sql), options: ExecuteOptions())
    }

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        try await ensureOpen()
        guard case .sql(let sql) = command else {
            throw AdapterError.engineMismatch
        }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MySQLAdapterError.failure("MySQL query cannot be empty.")
        }
        if input.readOnly || profile.readOnly {
            try MySQLReadOnlyClassifier.assertReadOnly(sql)
        }
        try await state.begin(requestID: options.requestID)

        let startedAt = ContinuousClock.now
        do {
            let result = try await performQuery(sql: sql, options: options)
            let outcome = await state.finish(requestID: options.requestID)
            if outcome.timedOut { throw MySQLAdapterError.timedOut }
            if outcome.cancelled { throw MySQLAdapterError.cancelled }

            let maxRows = max(1, options.maxRows)
            let maxBytes = max(1, options.maxBytes)
            let bounded = MySQLValueMapping.boundedRows(
                rawRows: result.rows,
                maxRows: maxRows,
                maxBytes: maxBytes
            )
            let elapsed = ContinuousClock.now - startedAt
            return .rows(
                columns: MySQLValueMapping.columnMeta(result.columns),
                rows: bounded.rows,
                meta: ResultMeta(
                    count: bounded.rows.count,
                    truncated: bounded.truncated,
                    elapsedMilliseconds: max(0, elapsed.milliseconds)
                )
            )
        } catch let error as MySQLAdapterError {
            _ = await state.finish(requestID: options.requestID)
            throw error
        } catch let error as AdapterError {
            _ = await state.finish(requestID: options.requestID)
            throw error
        } catch {
            let outcome = await state.finish(requestID: options.requestID)
            if outcome.timedOut || Self.isStatementTimeout(error) {
                throw MySQLAdapterError.timedOut
            }
            if outcome.cancelled || Self.isQueryInterrupted(error) {
                throw MySQLAdapterError.cancelled
            }
            throw sanitized("MySQL query failed", error)
        }
    }

    public func cancel(requestID: UUID) async throws {
        guard let threadID = await state.cancel(requestID: requestID) else { return }
        do {
            try await killQuery(threadID: threadID)
        } catch {
            throw sanitized("Could not cancel MySQL query", error)
        }
    }

    public func close() async {
        let wasClosed = await state.markClosed()
        guard !wasClosed else { return }
        let threadIDs = await state.cancelAll()
        for threadID in threadIDs {
            try? await killQuery(threadID: threadID)
        }
        await pool.close()
        // `shutdownGracefully() async` only fails when the group is already shut
        // down, in which case there is nothing left to do.
        try? await group.shutdownGracefully()
    }

    // MARK: - Internals

    private func ensureOpen() async throws {
        if await state.closed {
            throw AdapterError.sessionClosed
        }
    }

    private func performQuery(sql: String, options: ExecuteOptions) async throws -> MySQLTextQueryResult {
        if await state.isCancelled(options.requestID) {
            throw MySQLAdapterError.cancelled
        }
        let lease: MySQLLease
        do {
            lease = try await pool.checkout()
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("Could not connect to MySQL", error)
        }
        await state.activate(requestID: options.requestID, threadID: lease.threadID)
        if await state.isCancelled(options.requestID) {
            await pool.checkin(lease, healthy: true)
            throw MySQLAdapterError.cancelled
        }

        // Server-side timeout: after the budget expires, mark the request and
        // interrupt the query with KILL QUERY on a dedicated connection.
        let timeoutTask = Task { [state] in
            guard options.timeout > .zero else { return }
            try? await Task.sleep(for: options.timeout)
            guard !Task.isCancelled else { return }
            if let threadID = await state.timeout(requestID: options.requestID) {
                try? await self.killQuery(threadID: threadID)
            }
        }
        defer { timeoutTask.cancel() }

        do {
            let result = try await lease.connection.textQuery(sql).get()
            await pool.checkin(lease, healthy: true)
            return result
        } catch {
            await pool.checkin(lease, healthy: !Self.isConnectionFailure(error))
            throw error
        }
    }

    private func withLease<T: Sendable>(
        _ body: (MySQLLease) async throws -> T
    ) async throws -> T {
        let lease = try await pool.checkout()
        do {
            let result = try await body(lease)
            await pool.checkin(lease, healthy: true)
            return result
        } catch {
            await pool.checkin(lease, healthy: !Self.isConnectionFailure(error))
            throw error
        }
    }

    /// `KILL QUERY` runs on a dedicated out-of-pool connection so cancellation
    /// never queues behind a saturated pool. ER_NO_SUCH_THREAD is tolerated:
    /// the query already finished, which is what cancellation wanted anyway.
    private func killQuery(threadID: UInt64) async throws {
        let connection = try await MySQLConnector.connect(
            config: config,
            session: .kill,
            on: group.next(),
            logger: logger
        )
        do {
            _ = try await connection.simpleQuery("KILL QUERY \(threadID)").get()
        } catch {
            try? await connection.close().get()
            if MySQLErrorSanitizer.serverError(error, is: .NO_SUCH_THREAD) {
                return
            }
            throw error
        }
        try? await connection.close().get()
    }

    /// Server errors leave the connection usable; transport/protocol failures do not.
    static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let mysqlError = error as? MySQLError else { return true }
        switch mysqlError {
        case .server, .duplicateEntry, .invalidSyntax:
            return false
        default:
            return true
        }
    }

    /// ER_QUERY_INTERRUPTED (1317): the server aborted the query after KILL QUERY.
    static func isQueryInterrupted(_ error: any Error) -> Bool {
        if MySQLErrorSanitizer.serverError(error, is: .QUERY_INTERRUPTED) { return true }
        let message = (error as? MySQLError)?.message ?? ""
        return message.range(of: "query execution was interrupted", options: .caseInsensitive) != nil
    }

    /// ER_QUERY_TIMEOUT (3024) and MariaDB's max_statement_time (1938).
    static func isStatementTimeout(_ error: any Error) -> Bool {
        if MySQLErrorSanitizer.serverError(error, is: .QUERY_TIMEOUT) { return true }
        if MySQLErrorSanitizer.serverError(error, is: MySQLProtocol.ErrorCode(integerLiteral: 1938)) { return true }
        let message = (error as? MySQLError)?.message ?? ""
        return message.range(
            of: #"max(?:imum)?[_ ](?:execution|statement)[_ ]time"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private func sanitized(_ action: String, _ error: any Error) -> MySQLAdapterError {
        MySQLErrorSanitizer.sanitize(action: action, error: error, secrets: [input.password])
    }
}

// MARK: - Importing

extension MySQLAdapter: SupportsImporting {
    /// Insertable columns of the import target; generated columns are excluded.
    private static let listInsertableColumnsSQL = """
        SELECT COLUMN_NAME
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = ?
          AND TABLE_NAME = ?
          AND GENERATION_EXPRESSION = ''
        ORDER BY ORDINAL_POSITION
        """

    /// Streams a CSV file into one introspected table, following the Electron
    /// PostgreSQL adapter's semantics: one transaction around the whole file,
    /// rolled back when any batch fails. Values cross as string binds; the
    /// server coerces them into the column types on INSERT.
    public func importData(_ request: ImportRequest) async throws -> ImportSummary {
        try await ensureOpen()
        if input.readOnly || profile.readOnly {
            throw ImportError.unsupported(
                "MySQL import is disabled for read-only connections.")
        }
        guard request.format == .csv else {
            throw ImportError.unsupported("MySQL imports accept CSV files.")
        }
        guard let ref = await state.objectRef(for: request.target.id),
              ref.kind == .table,
              let name = ref.name
        else {
            throw AdapterError.notFound("MySQL import requires an introspected table target.")
        }

        let lease = try await pool.checkout()
        var inTransaction = false
        do {
            let metadataRows = try await lease.connection
                .query(Self.listInsertableColumnsSQL, [
                    MySQLData(string: ref.database),
                    MySQLData(string: name),
                ])
                .get()
            var columns: [String] = []
            var seen: Set<String> = []
            for row in metadataRows {
                guard let column = row.column("COLUMN_NAME")?.string,
                      !column.isEmpty, seen.insert(column).inserted
                else {
                    throw MySQLAdapterError.failure(
                        "MySQL returned invalid insertable-column metadata.")
                }
                columns.append(column)
            }
            guard !columns.isEmpty else {
                throw MySQLAdapterError.failure(
                    "MySQL import target has no insertable columns.")
            }
            let allowedColumns = Set(columns)
            let batchSize = try MySQLImportPlanner.batchSize(columnCount: columns.count)

            if request.isCancelled() { throw ImportError.cancelled }
            _ = try await lease.connection.simpleQuery("START TRANSACTION").get()
            inTransaction = true

            let summary = try await CSVImportDriver.run(
                fileURL: request.fileURL,
                hasHeader: request.hasHeader,
                knownColumns: columns,
                batchSize: batchSize,
                isCancelled: request.isCancelled,
                onProgress: request.onProgress,
                insertBatch: { targets, rows in
                    guard targets.allSatisfy(allowedColumns.contains) else {
                        throw MySQLAdapterError.failure(
                            "MySQL import batch contains an invalid column mapping.")
                    }
                    let sql = try MySQLImportPlanner.insertStatement(
                        database: ref.database, table: name,
                        columns: targets, rowCount: rows.count)
                    var binds: [MySQLData] = []
                    binds.reserveCapacity(rows.count * targets.count)
                    for row in rows {
                        guard row.count == targets.count else {
                            throw MySQLAdapterError.failure(
                                "MySQL import batch has inconsistent columns.")
                        }
                        for value in row {
                            binds.append(MySQLData(string: value))
                        }
                    }
                    _ = try await lease.connection.query(sql, binds).get()
                    return rows.count
                })

            if request.isCancelled() { throw ImportError.cancelled }
            _ = try await lease.connection.simpleQuery("COMMIT").get()
            inTransaction = false
            await pool.checkin(lease, healthy: true)
            return summary
        } catch {
            if inTransaction {
                _ = try? await lease.connection.simpleQuery("ROLLBACK").get()
            }
            await pool.checkin(lease, healthy: !Self.isConnectionFailure(error))
            if let importError = error as? ImportError { throw importError }
            if let adapterError = error as? MySQLAdapterError { throw adapterError }
            if let adapterError = error as? AdapterError { throw adapterError }
            throw sanitized("MySQL import failed", error)
        }
    }
}

// MARK: - Editing

extension MySQLAdapter: SupportsEditing {
    /// Applies one reviewed single-row change inside a transaction on one
    /// leased connection: introspect + validate the change-target metadata,
    /// plan with the pure planner, and execute the parameterized statement.
    /// MySQL has no `RETURNING`, so the OK packet's affected-row count is the
    /// conflict signal: zero rows means the row changed or vanished underneath
    /// the edit (optimistic-concurrency conflict). Read-only sessions are
    /// refused client-side here and server-side via `transaction_read_only`.
    public func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        try await ensureOpen()
        if input.readOnly || profile.readOnly {
            throw MySQLAdapterError.failure(
                "MySQL row changes are disabled for read-only connections.")
        }
        guard let ref = await state.objectRef(for: change.object.id),
              ref.kind == .table,
              let name = ref.name
        else {
            throw AdapterError.notFound("MySQL row changes require an introspected table target.")
        }

        let startedAt = ContinuousClock.now
        let lease = try await pool.checkout()
        var inTransaction = false
        do {
            _ = try await lease.connection.simpleQuery("START TRANSACTION").get()
            inTransaction = true

            let metadataRows = try await lease.connection
                .query(MySQLChangePlanner.listTableChangeColumnsSQL, [
                    MySQLData(string: ref.database),
                    MySQLData(string: name),
                ])
                .get()
            let metadata = try MySQLChangePlanner.changeTableMetadata(
                rows: Self.changeMetadataRows(from: metadataRows))

            let original = try MySQLChangeMapper.orderedEntries(
                change.original, metadata: metadata, label: "MySQL original values")
            let current: [MySQLFieldEntry]?
            switch change.operation {
            case .update(let changed):
                current = try MySQLChangeMapper.currentEntries(original: original, changed: changed)
            case .delete:
                current = nil
            }
            let primaryKey = try MySQLChangeMapper.primaryKeyEntries(
                metadata: metadata, original: original)

            let plan: MySQLParameterizedPlan
            if let current {
                plan = try MySQLChangePlanner.planUpdate(
                    database: ref.database, table: name,
                    primaryKey: primaryKey, original: original, current: current)
            } else {
                plan = try MySQLChangePlanner.planDelete(
                    database: ref.database, table: name,
                    primaryKey: primaryKey, original: original)
            }

            let bindColumns = MySQLChangeMapper.bindColumns(
                primaryKey: primaryKey, original: original, current: current)
            guard bindColumns.count == plan.values.count else {
                throw MySQLAdapterError.failure("MySQL change planning failed.")
            }
            var binds: [MySQLData] = []
            binds.reserveCapacity(plan.values.count)
            for (column, value) in zip(bindColumns, plan.values) {
                binds.append(try MySQLChangeMapper.bind(for: value, label: column))
            }

            nonisolated(unsafe) var affectedRows: UInt64?
            _ = try await lease.connection
                .query(plan.text, binds, onMetadata: { affectedRows = $0.affectedRows })
                .get()
            guard let affectedRows else {
                throw MySQLAdapterError.failure("MySQL change planning failed.")
            }
            guard affectedRows > 0 else {
                throw MySQLAdapterError.failure(
                    "MySQL optimistic-concurrency conflict: the row changed or no longer exists.")
            }
            guard affectedRows == 1 else {
                throw MySQLAdapterError.failure(
                    "MySQL refused a row change with an unexpected affected-row count.")
            }

            _ = try await lease.connection.simpleQuery("COMMIT").get()
            inTransaction = false
            await pool.checkin(lease, healthy: true)
            let elapsed = ContinuousClock.now - startedAt
            return .rows(
                columns: [],
                rows: [],
                meta: ResultMeta(
                    count: 1, truncated: false, elapsedMilliseconds: max(0, elapsed.milliseconds)))
        } catch {
            if inTransaction {
                _ = try? await lease.connection.simpleQuery("ROLLBACK").get()
            }
            await pool.checkin(lease, healthy: !Self.isConnectionFailure(error))
            if let planError = error as? MySQLChangePlanError { throw planError }
            if let adapterError = error as? MySQLAdapterError { throw adapterError }
            if let adapterError = error as? AdapterError { throw adapterError }
            throw sanitized("MySQL data change failed", error)
        }
    }

    /// Decodes `(COLUMN_NAME, DATA_TYPE, primary_key_ordinal)` introspection
    /// rows into the planner's metadata input.
    private static func changeMetadataRows(
        from rows: [MySQLRow]
    ) throws -> [(name: String, dataType: String, primaryKeyOrdinal: Int)] {
        try rows.map { row in
            guard let name = row.column("COLUMN_NAME")?.string,
                  let dataType = row.column("DATA_TYPE")?.string,
                  let ordinal = row.column("primary_key_ordinal")?.int
            else {
                throw MySQLAdapterError.failure(
                    "MySQL returned invalid table-change metadata.")
            }
            return (name, dataType, ordinal)
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = self.components
        let millis = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: millis)
    }
}
