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

extension MySQLObjectRef {
    /// Decodes an id produced by `id`; returns nil for foreign handles.
    init?(id: String) {
        let prefix = "mysql:"
        guard id.hasPrefix(prefix),
              let data = Data(base64Encoded: String(id.dropFirst(prefix.count))),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
              payload.count == 3,
              let kindRaw = payload[0] as? String,
              let kind = Kind(rawValue: kindRaw),
              let database = payload[1] as? String
        else { return nil }
        let name = payload[2] is NSNull ? nil : payload[2] as? String
        self.init(kind: kind, database: database, name: name)
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

    /// Pre-registers cancellation, even for a request that has not started
    /// yet; execute checks the set before touching the pool. Returns the
    /// thread id to kill when the query is already running.
    func cancel(requestID: UUID) -> UInt64? {
        cancelledRequestIDs.insert(requestID)
        return executions[requestID]?.threadID
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

    /// Server-wide listing for connections without a default schema: every
    /// non-system schema becomes a `.database` parent node with its tables
    /// and views as children. The object refs carry the schema name, so
    /// preview/editing/import stay correctly qualified.
    private static let listServerWideObjectsSQL = """
        SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
        ORDER BY TABLE_SCHEMA, TABLE_NAME
        """

    public init(input: ConnectionInput.MySQLInput) throws {
        guard !input.host.trimmingCharacters(in: .whitespaces).isEmpty,
              (1...65535).contains(input.port),
              !input.username.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw MySQLAdapterError.invalidConfiguration
        }
        // An empty database connects without a default schema; `listObjects`
        // then browses server-wide. (This mysql-nio version's `connect` takes
        // a non-optional database and always sets CLIENT_CONNECT_WITH_DB; an
        // empty schema name leaves the session without a default schema.)
        var input = input
        input.database = input.database.trimmingCharacters(in: .whitespaces)
        self.input = input
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .mysql,
            endpoint: "\(input.host):\(input.port)",
            database: input.database.isEmpty ? "server-wide" : input.database,
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
        if input.database.isEmpty {
            return try await listServerWideObjects()
        }
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

    /// Server-wide tree for connections without a default schema: non-system
    /// schemas as `.database` parents, their tables/views as children. Rows
    /// carry their own TABLE_SCHEMA, so each child ref is fully qualified.
    private func listServerWideObjects() async throws -> [DatabaseObject] {
        let rawRows: [MySQLRow]
        do {
            rawRows = try await withLease { lease in
                try await lease.connection.simpleQuery(Self.listServerWideObjectsSQL).get()
            }
        } catch {
            throw sanitized("Could not list MySQL objects", error)
        }

        var rows: [(schema: String, name: String, type: String)] = []
        for row in rawRows {
            guard let schema = row.column("TABLE_SCHEMA")?.string, !schema.isEmpty,
                  let name = row.column("TABLE_NAME")?.string, !name.isEmpty,
                  let type = row.column("TABLE_TYPE")?.string
            else {
                throw MySQLAdapterError.failure("Could not list MySQL objects: invalid object metadata.")
            }
            rows.append((schema, name, type))
        }

        let tree = try Self.serverWideTree(rows: rows)
        await state.setObjects(tree.refs)
        return tree.objects
    }

    /// Pure tree assembly for the server-wide listing: first-seen schema
    /// order (the query already sorts), one `.database` parent per schema,
    /// children fully qualified through their refs. Unit-tested offline.
    static func serverWideTree(
        rows: [(schema: String, name: String, type: String)]
    ) throws -> (objects: [DatabaseObject], refs: [String: MySQLObjectRef]) {
        var schemaOrder: [String] = []
        var bySchema: [String: [MySQLObjectRef]] = [:]
        for row in rows {
            let kind: MySQLObjectRef.Kind? =
                row.type == "BASE TABLE" ? .table :
                row.type == "VIEW" ? .view : nil
            guard let kind else { continue }
            if bySchema[row.schema] == nil {
                bySchema[row.schema] = []
                schemaOrder.append(row.schema)
            }
            bySchema[row.schema]?.append(
                MySQLObjectRef(kind: kind, database: row.schema, name: row.name))
        }

        var objects: [DatabaseObject] = []
        var refs: [String: MySQLObjectRef] = [:]
        for schema in schemaOrder {
            let databaseRef = MySQLObjectRef(kind: .database, database: schema, name: nil)
            refs[databaseRef.id] = databaseRef
            objects.append(DatabaseObject(
                id: databaseRef.id, parentID: nil, name: schema, kind: .database))
            for ref in bySchema[schema] ?? [] {
                refs[ref.id] = ref
                objects.append(DatabaseObject(
                    id: ref.id,
                    parentID: databaseRef.id,
                    name: ref.name ?? "",
                    kind: ref.kind == .view ? .view : .table
                ))
            }
        }
        return (objects, refs)
    }

    public func previewObject(_ request: PreviewRequest) async throws -> QueryResult {
        try await ensureOpen()
        // The codec-decode fallback lets foreign-key jump targets preview
        // directly: their ids are minted by the same `MySQLObjectRef` codec
        // but may belong to a schema `listObjects` never cached (cross-schema
        // references, server-wide connections).
        guard let ref = await state.objectRef(for: request.object.id)
                ?? MySQLObjectRef(id: request.object.id),
              ref.kind != .database,
              let name = ref.name
        else {
            throw AdapterError.notFound("This MySQL object cannot be previewed.")
        }
        let plan = try MySQLPreviewPlanner.plan(database: ref.database, table: name, request: request)
        // maxRows = page size; the SQL's LIMIT is one larger, so a truncated
        // result means a next page exists.
        let options = ExecuteOptions(requestID: request.requestID, maxRows: plan.limit)
        guard plan.filterPattern != nil || plan.bindEqualitiesStatement != nil else {
            return try await runSQL(plan.text, preset: nil, options: options)
        }
        // The filter/equality values cross as binary-protocol binds into
        // session variables on the leased connection; the preview SELECT
        // itself stays on the text protocol, so display semantics match
        // unfiltered previews. Equality binds go through the change path's
        // DisplayValue conversion (integral numbers as integers, display
        // strings as text the server coerces back).
        return try await runSQL(plan.text, preset: { connection in
            if let pattern = plan.filterPattern {
                _ = try await connection.query(
                    MySQLPreviewPlanner.bindFilterStatement, [MySQLData(string: pattern)]).get()
            }
            if let statement = plan.bindEqualitiesStatement {
                var binds: [MySQLData] = []
                binds.reserveCapacity(plan.equalityValues.count)
                for value in plan.equalityValues {
                    binds.append(try MySQLChangeMapper.bind(
                        for: value, label: "MySQL preview equality value"))
                }
                _ = try await connection.query(statement, binds).get()
            }
        }, options: options)
    }

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        guard case .sql(let sql) = command else {
            throw AdapterError.engineMismatch
        }
        return try await runSQL(sql, preset: nil, options: options)
    }

    /// The shared execution core for ad-hoc SQL and planned previews. `preset`
    /// runs one parameterized statement on the leased connection right before
    /// the main text query (the filtered preview's session-variable bind).
    private func runSQL(
        _ sql: String,
        preset: (@Sendable (MySQLConnection) async throws -> Void)?,
        options: ExecuteOptions
    ) async throws -> QueryResult {
        try await ensureOpen()
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MySQLAdapterError.failure("MySQL query cannot be empty.")
        }
        if input.readOnly || profile.readOnly {
            try MySQLReadOnlyClassifier.assertReadOnly(sql)
        }
        try await state.begin(requestID: options.requestID)

        let startedAt = ContinuousClock.now
        let maxRows = max(1, options.maxRows)
        do {
            let result = try await performQuery(sql: sql, options: options, rowLimit: maxRows + 1, preset: preset)
            let outcome = await state.finish(requestID: options.requestID)
            if outcome.timedOut { throw MySQLAdapterError.timedOut }
            if outcome.cancelled { throw MySQLAdapterError.cancelled }

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

    private func performQuery(
        sql: String,
        options: ExecuteOptions,
        rowLimit: Int,
        preset: (@Sendable (MySQLConnection) async throws -> Void)? = nil
    ) async throws -> MySQLTextQueryResult {
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
            if let preset { try await preset(lease.connection) }
            let result = try await lease.connection.textQuery(sql, rowLimit: rowLimit).get()
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

    /// Backtick-quote a MySQL identifier (backticks doubled), same rule the
    /// preview path uses. Also used by `SelectStatementBuilder`.
    public static func quoteIdentifier(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private func sanitized(_ action: String, _ error: any Error) -> MySQLAdapterError {
        MySQLErrorSanitizer.sanitize(action: action, error: error, secrets: [input.password])
    }
}

// MARK: - Introspection

extension MySQLAdapter: SupportsIntrospection {
    /// `SHOW CREATE TABLE` / `SHOW CREATE VIEW` against the ref's own schema,
    /// so server-wide (database-less) connections stay correctly qualified.
    /// Reading DDL is a read: allowed on read-only profiles.
    public func createStatement(for object: DatabaseObject) async throws -> String {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id),
              ref.kind == .table || ref.kind == .view,
              let name = ref.name
        else {
            throw AdapterError.notFound(
                "MySQL create statements require an introspected table or view target.")
        }
        let sql = MySQLIntrospectionPlanner.showCreateStatementSQL(
            database: ref.database, name: name, isView: ref.kind == .view)
        do {
            let rows = try await withLease { lease in
                try await lease.connection.simpleQuery(sql).get()
            }
            guard let row = rows.first,
                  let ddl = row.column("Create Table")?.string
                    ?? row.column("Create View")?.string,
                  !ddl.isEmpty
            else {
                throw MySQLAdapterError.failure(
                    "MySQL returned no create statement for this object.")
            }
            return ddl
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("Could not read the MySQL create statement", error)
        }
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

            let plan: MySQLParameterizedPlan
            let bindColumns: [String]
            switch change.operation {
            case .insert(let values):
                // No optimistic lock for a row that does not exist yet; the
                // reviewed values are catalog-ordered like the original patch.
                let entries = try MySQLChangeMapper.orderedEntries(
                    values, metadata: metadata, label: "MySQL insert values")
                plan = try MySQLChangePlanner.planInsert(
                    database: ref.database, table: name, entries: entries)
                bindColumns = entries.map(\.column)
            case .update, .delete:
                let original = try MySQLChangeMapper.orderedEntries(
                    change.original, metadata: metadata, label: "MySQL original values")
                let current: [MySQLFieldEntry]?
                if case .update(let changed) = change.operation {
                    current = try MySQLChangeMapper.currentEntries(original: original, changed: changed)
                } else {
                    current = nil
                }
                let primaryKey = try MySQLChangeMapper.primaryKeyEntries(
                    metadata: metadata, original: original)
                if let current {
                    plan = try MySQLChangePlanner.planUpdate(
                        database: ref.database, table: name, columnTypes: metadata.columnTypes,
                        primaryKey: primaryKey, original: original, current: current)
                } else {
                    plan = try MySQLChangePlanner.planDelete(
                        database: ref.database, table: name, columnTypes: metadata.columnTypes,
                        primaryKey: primaryKey, original: original)
                }
                bindColumns = MySQLChangeMapper.bindColumns(
                    primaryKey: primaryKey, original: original, current: current)
            }
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

    /// Insertable columns for building insert drafts — the same introspection
    /// and validation as `applyDataChange` (generated columns excluded,
    /// round-trip refusal list enforced). Reading metadata is a read:
    /// read-only profiles still allow it.
    public func insertableColumns(for object: DatabaseObject) async throws -> [InsertableColumn] {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id),
              ref.kind == .table,
              let name = ref.name
        else {
            throw AdapterError.notFound("MySQL insert drafts require an introspected table target.")
        }

        let lease = try await pool.checkout()
        do {
            let rows = try await lease.connection
                .query(MySQLChangePlanner.listTableChangeColumnsSQL, [
                    MySQLData(string: ref.database),
                    MySQLData(string: name),
                ])
                .get()
            let metadata = try MySQLChangePlanner.changeTableMetadata(
                rows: Self.changeMetadataRows(from: rows))
            await pool.checkin(lease, healthy: true)
            let ordinals = Dictionary(
                metadata.primaryKey.enumerated().map { ($0.element, $0.offset + 1) }) { first, _ in first }
            return metadata.columns.map {
                InsertableColumn(name: $0, primaryKeyOrdinal: ordinals[$0] ?? 0)
            }
        } catch {
            await pool.checkin(lease, healthy: !Self.isConnectionFailure(error))
            if let planError = error as? MySQLChangePlanError { throw planError }
            if let adapterError = error as? MySQLAdapterError { throw adapterError }
            if let adapterError = error as? AdapterError { throw adapterError }
            throw sanitized("MySQL could not read the table columns", error)
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

// MARK: - Foreign keys

extension MySQLAdapter: SupportsForeignKeys {
    /// Foreign keys of one introspected table (ROADMAP M1 ⑤), grouped by
    /// constraint with ordinal column pairing. The query is parameterized and
    /// qualified by the object's own schema; referenced rows carry their own
    /// schema, so server-wide connections stay correct. Reading metadata is a
    /// read: read-only profiles still allow it.
    public func foreignKeys(for object: DatabaseObject) async throws -> [ForeignKey] {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id) ?? MySQLObjectRef(id: object.id),
              ref.kind != .database,
              let name = ref.name
        else {
            throw AdapterError.notFound("MySQL foreign keys require an introspected table target.")
        }
        do {
            let rows = try await withLease { lease in
                try await lease.connection
                    .query(MySQLForeignKeyPlanner.listForeignKeysSQL, [
                        MySQLData(string: ref.database),
                        MySQLData(string: name),
                    ])
                    .get()
            }
            var parsed: [(constraint: String, column: String, referencedSchema: String,
                          referencedTable: String, referencedColumn: String)] = []
            for row in rows {
                guard let constraint = row.column("CONSTRAINT_NAME")?.string,
                      let column = row.column("COLUMN_NAME")?.string,
                      let referencedSchema = row.column("REFERENCED_TABLE_SCHEMA")?.string,
                      let referencedTable = row.column("REFERENCED_TABLE_NAME")?.string,
                      let referencedColumn = row.column("REFERENCED_COLUMN_NAME")?.string
                else {
                    throw MySQLAdapterError.failure(
                        "MySQL returned invalid foreign-key metadata.")
                }
                parsed.append((constraint, column, referencedSchema, referencedTable, referencedColumn))
            }
            return try MySQLForeignKeyPlanner.foreignKeys(rows: parsed)
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("MySQL could not read the foreign keys", error)
        }
    }
}

// MARK: - Table statistics

extension MySQLAdapter: SupportsTableStatistics {
    /// information_schema statistics for one introspected table or view
    /// (ROADMAP M2 ⑩), parameterized and qualified by the object's own
    /// schema so server-wide connections stay correct. TABLE_ROWS is
    /// InnoDB's estimate; NULLs (views, missing stats) map to nil. Reading
    /// statistics is a read: read-only profiles still allow it.
    public func tableStatistics(for object: DatabaseObject) async throws -> TableStatistics {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id) ?? MySQLObjectRef(id: object.id),
              ref.kind == .table || ref.kind == .view,
              let name = ref.name
        else {
            throw AdapterError.notFound(
                "MySQL statistics require an introspected table or view target.")
        }
        do {
            let rows = try await withLease { lease in
                try await lease.connection
                    .query(MySQLStatisticsPlanner.statisticsSQL, [
                        MySQLData(string: ref.database),
                        MySQLData(string: name),
                    ])
                    .get()
            }
            guard let row = rows.first else {
                throw AdapterError.notFound(
                    "This MySQL object no longer exists. Refresh the object list and try again.")
            }
            return MySQLStatisticsPlanner.statistics(
                rows: row.column("TABLE_ROWS")?.string,
                dataBytes: row.column("DATA_LENGTH")?.string,
                indexBytes: row.column("INDEX_LENGTH")?.string)
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("MySQL could not read the table statistics", error)
        }
    }
}

// MARK: - Server activity

extension MySQLAdapter: SupportsServerActivity {
    /// `SHOW FULL PROCESSLIST` (ROADMAP M2 ⑨): every server thread with its
    /// statement excerpt. Reading the process list is a read: read-only
    /// profiles still allow it.
    public func listActivity() async throws -> [ServerActivity] {
        try await ensureOpen()
        do {
            let rows = try await withLease { lease in
                try await lease.connection.simpleQuery(MySQLActivityPlanner.listActivitySQL).get()
            }
            var activities: [ServerActivity] = []
            for row in rows {
                if let activity = MySQLActivityPlanner.activity(
                    id: MySQLActivityPlanner.uint64(row.column("Id")?.string),
                    user: row.column("User")?.string,
                    database: row.column("db")?.string,
                    command: row.column("Command")?.string,
                    state: row.column("State")?.string,
                    timeSeconds: MySQLActivityPlanner.uint64(row.column("Time")?.string),
                    info: row.column("Info")?.string) {
                    activities.append(activity)
                }
            }
            return activities
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("MySQL could not list the server activity", error)
        }
    }

    /// Kills one thread with `KILL` — the full connection kill a process list
    /// implies (`KILL QUERY` would stop only the current statement and leave
    /// the session listed). The session layer gates kills to writable
    /// profiles; the adapter re-checks. Runs on a dedicated out-of-pool
    /// connection like the cancel path, so killing our own in-flight query
    /// never queues behind a saturated pool. ER_NO_SUCH_THREAD is tolerated:
    /// the target already finished, which is what the kill wanted anyway.
    public func killActivity(id: String) async throws {
        try await ensureOpen()
        if input.readOnly || profile.readOnly {
            throw MySQLAdapterError.failure(
                "MySQL activity kills are disabled for read-only connections.")
        }
        guard let threadID = UInt64(id) else {
            throw AdapterError.notFound("This MySQL activity id is no longer valid.")
        }
        let connection = try await MySQLConnector.connect(
            config: config,
            session: .kill,
            on: group.next(),
            logger: logger
        )
        do {
            _ = try await connection.simpleQuery(
                MySQLActivityPlanner.killStatement(threadID: threadID)).get()
        } catch {
            try? await connection.close().get()
            if MySQLErrorSanitizer.serverError(error, is: .NO_SUCH_THREAD) {
                return
            }
            throw sanitized("Could not kill the MySQL thread", error)
        }
        try? await connection.close().get()
    }
}

// MARK: - Schema introspection

extension MySQLAdapter: SupportsSchemaIntrospection {
    /// Structured schema of one introspected table or view: columns with
    /// nullability and primary-key ordinals, grouped indexes (PRIMARY
    /// included), and foreign keys (the `SupportsForeignKeys` query; views
    /// have none). Parameterized and qualified by the object's own schema, so
    /// server-wide connections stay correct. Reading metadata is a read:
    /// read-only profiles still allow it.
    public func schema(for object: DatabaseObject) async throws -> TableSchema {
        try await ensureOpen()
        guard let ref = await state.objectRef(for: object.id) ?? MySQLObjectRef(id: object.id),
              ref.kind == .table || ref.kind == .view,
              let name = ref.name
        else {
            throw AdapterError.notFound(
                "MySQL schemas require an introspected table or view target.")
        }
        do {
            let columnRows = try await withLease { lease in
                try await lease.connection
                    .query(MySQLSchemaPlanner.listColumnsSQL, [
                        MySQLData(string: ref.database),
                        MySQLData(string: name),
                    ])
                    .get()
            }
            var parsedColumns: [(name: String, dataType: String, nullable: String,
                                 primaryKeyOrdinal: Int)] = []
            for row in columnRows {
                guard let columnName = row.column("COLUMN_NAME")?.string,
                      let dataType = row.column("COLUMN_TYPE")?.string,
                      let nullable = row.column("IS_NULLABLE")?.string,
                      let ordinalText = row.column("PK_ORDINAL")?.string,
                      let ordinal = Int(ordinalText)
                else {
                    throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
                }
                parsedColumns.append((columnName, dataType, nullable, ordinal))
            }
            let columns = try MySQLSchemaPlanner.columns(rows: parsedColumns)

            let indexRows = try await withLease { lease in
                try await lease.connection
                    .query(MySQLSchemaPlanner.listIndexesSQL, [
                        MySQLData(string: ref.database),
                        MySQLData(string: name),
                    ])
                    .get()
            }
            var parsedIndexes: [(name: String, nonUnique: String, column: String)] = []
            for row in indexRows {
                guard let indexName = row.column("INDEX_NAME")?.string,
                      let nonUnique = row.column("NON_UNIQUE")?.string,
                      let column = row.column("COLUMN_NAME")?.string
                else {
                    throw MySQLAdapterError.failure("MySQL returned invalid schema metadata.")
                }
                parsedIndexes.append((indexName, nonUnique, column))
            }
            let indexes = try MySQLSchemaPlanner.indexes(rows: parsedIndexes)

            // The foreign keys reuse the `SupportsForeignKeys` query path;
            // views simply have none.
            let keys: [ForeignKey] = ref.kind == .table ? try await foreignKeys(for: object) : []

            return TableSchema(object: object, columns: columns, foreignKeys: keys, indexes: indexes)
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("MySQL could not read the table schema", error)
        }
    }

    /// Every foreign-key edge of the connection's scope: the configured
    /// database, or all non-system schemas on a server-wide (database-less)
    /// connection. Reading metadata is a read: read-only profiles still
    /// allow it.
    public func allForeignKeys() async throws -> [TableRelation] {
        try await ensureOpen()
        do {
            let rows: [MySQLRow]
            if input.database.isEmpty {
                rows = try await withLease { lease in
                    try await lease.connection
                        .simpleQuery(MySQLSchemaPlanner.listServerWideForeignKeysSQL)
                        .get()
                }
            } else {
                rows = try await withLease { lease in
                    try await lease.connection
                        .query(MySQLSchemaPlanner.listAllForeignKeysSQL, [
                            MySQLData(string: self.input.database),
                        ])
                        .get()
                }
            }
            var parsed: [(schema: String, table: String, constraint: String, column: String,
                          referencedSchema: String, referencedTable: String,
                          referencedColumn: String)] = []
            for row in rows {
                guard let schema = row.column("TABLE_SCHEMA")?.string,
                      let table = row.column("TABLE_NAME")?.string,
                      let constraint = row.column("CONSTRAINT_NAME")?.string,
                      let column = row.column("COLUMN_NAME")?.string,
                      let referencedSchema = row.column("REFERENCED_TABLE_SCHEMA")?.string,
                      let referencedTable = row.column("REFERENCED_TABLE_NAME")?.string,
                      let referencedColumn = row.column("REFERENCED_COLUMN_NAME")?.string
                else {
                    throw MySQLAdapterError.failure(
                        "MySQL returned invalid foreign-key metadata.")
                }
                parsed.append((schema, table, constraint, column,
                               referencedSchema, referencedTable, referencedColumn))
            }
            return try MySQLSchemaPlanner.allForeignKeys(rows: parsed)
        } catch let error as MySQLAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw sanitized("MySQL could not read the foreign keys", error)
        }
    }
}
