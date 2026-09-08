import Foundation
import Synchronization
import GRDB
import dbbbbCore

/// SQLite adapter on GRDB's `DatabaseQueue`. Read-only sessions are doubly
/// guarded: the file is opened with `SQLITE_OPEN_READONLY` and every statement
/// passes the fail-closed classifier in `assertSQLiteReadOnlySQL`. Cancellation is
/// real here — GRDB exposes `sqlite3_interrupt` via `DatabaseQueue.interrupt()`.
///
/// The file is not opened at init (adapters are constructed on the main
/// thread when connections are restored); `DatabaseQueue` creation is
/// deferred to first use. All statements run synchronously on GRDB's
/// serialized writer queue, so a long query blocks one cooperative-thread-pool
/// thread until it finishes or is interrupted; `ExecuteOptions.timeout` is
/// enforced here by a watchdog that interrupts the queue through the same
/// mechanism as `cancel(requestID:)`.
public final class SQLiteAdapter: DatabaseAdapter, Sendable {
    public let profile: ConnectionProfile

    private let filePath: String
    private let readOnly: Bool

    // DatabaseQueue is @unchecked Sendable in GRDB, so the boxed state is too.
    private struct State: @unchecked Sendable {
        var queue: DatabaseQueue?
        var closed = false
    }

    private let state: Mutex<State>

    private static let maxValueBytes = 8 * 1024 * 1024
    private static let maxErrorLength = 600
    private static let safeIntegerBound: Int64 = 9_007_199_254_740_991 // 2^53 - 1

    private static let listObjectsSQL = """
        SELECT name, type
        FROM sqlite_master
        WHERE type IN ('table', 'view')
          AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """

    public init(input: ConnectionInput.SQLiteInput) throws {
        guard !input.filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !input.filePath.contains("\0")
        else {
            throw SQLiteAdapterError("SQLite connection settings are invalid.")
        }

        self.filePath = input.filePath
        self.readOnly = input.readOnly
        self.state = Mutex(State())
        self.profile = ConnectionProfile(
            name: input.name,
            engine: .sqlite,
            endpoint: input.filePath,
            database: (input.filePath as NSString).lastPathComponent,
            environment: input.environment,
            readOnly: input.readOnly
        )
    }

    // MARK: - DatabaseAdapter

    public func listObjects() async throws -> [DatabaseObject] {
        let queue = try currentQueue()
        do {
            return try await queue.read { db in
                let rows = try Row.fetchAll(db, sql: Self.listObjectsSQL)
                var objects = [DatabaseObject(
                    id: Self.objectID(kind: .schema, name: nil),
                    parentID: nil,
                    name: "main",
                    kind: .schema
                )]
                for row in rows {
                    let values = Array(row.databaseValues)
                    guard values.count == 2,
                          case .string(let name) = values[0].storage,
                          case .string(let type) = values[1].storage,
                          type == "table" || type == "view"
                    else {
                        throw SQLiteAdapterError("SQLite returned invalid object metadata.")
                    }
                    let kind: DatabaseObjectKind = type == "view" ? .view : .table
                    objects.append(DatabaseObject(
                        id: Self.objectID(kind: kind, name: name),
                        parentID: Self.objectID(kind: .schema, name: nil),
                        name: name,
                        kind: kind
                    ))
                }
                return objects
            }
        } catch let error as SQLiteAdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not list SQLite objects", error, filePath: filePath)
        }
    }

    public func previewObject(_ request: PreviewRequest) async throws -> QueryResult {
        guard request.object.kind == .table || request.object.kind == .view else {
            throw AdapterError.notFound("This SQLite object cannot be previewed.")
        }
        let plan = try SQLitePreviewPlanner.plan(table: request.object.name, request: request)
        // maxRows = page size; the SQL's LIMIT is one larger, so a truncated
        // result means a next page exists.
        var binds: [DatabaseValue] = []
        if let pattern = plan.filterPattern {
            binds.append(pattern.databaseValue)
        }
        binds.append(contentsOf: plan.equalityBinds)
        return try await runQuery(
            sql: plan.sql,
            binds: binds,
            options: ExecuteOptions(requestID: request.requestID, maxRows: plan.limit))
    }

    public func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        guard case .sql(let sql) = command else { throw AdapterError.engineMismatch }
        return try await runQuery(sql: sql, binds: [], options: options)
    }

    /// The shared execution core for ad-hoc SQL and planned previews.
    /// `binds` are the preview filter's bound `?` arguments — they never
    /// enter the SQL text.
    private func runQuery(sql: String, binds: [DatabaseValue], options: ExecuteOptions) async throws -> QueryResult {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SQLiteAdapterError("SQLite query cannot be empty.")
        }
        // prepare() would silently ignore anything after the first statement, so
        // multi-statement input is rejected for every profile, not just read-only.
        if readOnly {
            try assertSQLiteReadOnlySQL(sql)
        } else {
            _ = try inspectSQLiteSQL(sql)
        }

        let queue = try currentQueue()
        let startedAt = Date()

        // The timeout budget is enforced here: once it expires the watchdog
        // interrupts the queue through the same sqlite3_interrupt path as
        // cancel(requestID:), and the aborted statement surfaces as a timeout.
        // `settled` closes the window where a watchdog firing just after the
        // fetch finished would interrupt the next statement queued behind it.
        let timeoutState = Mutex((settled: false, fired: false))
        var watchdog: Task<Void, Never>?
        if options.timeout > .zero {
            watchdog = Task {
                try? await Task.sleep(for: options.timeout)
                guard !Task.isCancelled else { return }
                let shouldInterrupt = timeoutState.withLock { state -> Bool in
                    guard !state.settled else { return false }
                    state.fired = true
                    return true
                }
                if shouldInterrupt { queue.interrupt() }
            }
        }
        defer {
            watchdog?.cancel()
            timeoutState.withLock { $0.settled = true }
        }

        do {
            let fetched = try await queue.read { db in
                try Self.fetchRows(db: db, sql: sql, options: options, binds: binds)
            }
            let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
            return .rows(
                columns: Self.resultColumns(fetched),
                rows: fetched.rows,
                meta: ResultMeta(count: fetched.rows.count, truncated: fetched.truncated, elapsedMilliseconds: elapsed)
            )
        } catch let error as SQLiteAdapterError {
            throw error
        } catch {
            if timeoutState.withLock({ $0.fired }) {
                throw SQLiteAdapterError("SQLite query timed out.")
            }
            throw Self.sanitizedError("SQLite query failed", error, filePath: filePath)
        }
    }

    /// GRDB wraps `sqlite3_interrupt`, so cancellation is real: the running
    /// statement aborts with SQLITE_INTERRUPT and `execute` rethrows it as a
    /// sanitized error. The request ID is accepted for contract parity; a
    /// `DatabaseQueue` runs one statement at a time, so interrupting the queue
    /// interrupts exactly the in-flight request.
    public func cancel(requestID: UUID) async throws {
        try currentQueue().interrupt()
    }

    public func close() async {
        state.withLock { state in
            state.queue = nil
            state.closed = true
        }
    }

    // MARK: - Fetching

    private struct ColumnTracker: Sendable {
        var typeName: String?
        var allNumeric = true
    }

    private struct FetchedRows: Sendable {
        var columnNames: [String]
        var trackers: [ColumnTracker]
        var rows: [[DisplayValue]] = []
        var bytes = 0
        var truncated = false
    }

    private static func fetchRows(
        db: Database,
        sql: String,
        options: ExecuteOptions,
        binds: [DatabaseValue] = []
    ) throws -> FetchedRows {
        let statement = try db.makeStatement(sql: sql)
        var fetched = FetchedRows(
            columnNames: statement.columnNames,
            trackers: [ColumnTracker](repeating: ColumnTracker(), count: statement.columnNames.count)
        )

        let cursor = try Row.fetchCursor(
            statement,
            arguments: binds.isEmpty ? nil : StatementArguments(binds))
        while let row = try cursor.next() {
            if fetched.rows.count >= options.maxRows {
                fetched.truncated = true
                break
            }

            let databaseValues = Array(row.databaseValues)
            let values = databaseValues.map(displayValue(for:))
            let rowBytes = values.reduce(0) { $0 + byteSize(of: $1) }
            if fetched.bytes + rowBytes > options.maxBytes {
                fetched.truncated = true
                break
            }

            for (index, databaseValue) in databaseValues.enumerated() where index < fetched.trackers.count {
                switch databaseValue.storage {
                case .null: break
                case .int64: fetched.trackers[index].typeName = fetched.trackers[index].typeName ?? "INTEGER"
                case .double: fetched.trackers[index].typeName = fetched.trackers[index].typeName ?? "REAL"
                case .string:
                    fetched.trackers[index].typeName = fetched.trackers[index].typeName ?? "TEXT"
                    fetched.trackers[index].allNumeric = false
                case .blob:
                    fetched.trackers[index].typeName = fetched.trackers[index].typeName ?? "BLOB"
                    fetched.trackers[index].allNumeric = false
                }
            }

            fetched.bytes += rowBytes
            fetched.rows.append(values)
        }
        return fetched
    }

    /// GRDB does not expose `sqlite3_column_decltype`, so the reported type is
    /// the SQLite storage class of the first observed non-null value and
    /// `numeric` holds when every observed non-null value is INTEGER/REAL —
    /// the same right-alignment decision the affinity rules would produce.
    private static func resultColumns(_ fetched: FetchedRows) -> [ColumnMeta] {
        var counts: [String: Int] = [:]
        return fetched.columnNames.enumerated().map { index, rawName in
            let label = rawName.isEmpty ? "column_\(index + 1)" : rawName
            let count = counts[label] ?? 0
            counts[label] = count + 1
            let tracker = fetched.trackers[index]
            return ColumnMeta(
                name: count == 0 ? label : "\(label):\(count)",
                typeName: tracker.typeName ?? "unknown",
                numeric: tracker.allNumeric
            )
        }
    }

    // MARK: - Value conversion

    // Internal (not private) so tests can reach non-finite-double rendering;
    // SQLite itself folds NaN to NULL, so no SQL round-trip can produce one.
    static func displayValue(for value: DatabaseValue) -> DisplayValue {
        switch value.storage {
        case .null:
            .null
        case .int64(let int):
            // Precision never silently degrades: past the safe-integer range
            // bigints cross as strings.
            if (-safeIntegerBound...safeIntegerBound).contains(int) {
                .number(Double(int))
            } else {
                .string(String(int))
            }
        case .double(let double):
            if double.isNaN {
                .string("NaN")
            } else if double.isFinite {
                .number(double)
            } else {
                .string(double > 0 ? "Infinity" : "-Infinity")
            }
        case .string(let string):
            .string(boundedString(string))
        case .blob(let data):
            .binary(boundedData(data))
        }
    }

    private static func truncatedMarker(omittedBytes: Int) -> String {
        "…[dbbbb truncated \(omittedBytes) bytes]"
    }

    // A single oversized value must not materialize in full before the row
    // byte budget applies; truncate it and mark the result visibly incomplete.
    private static func boundedString(_ text: String) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > maxValueBytes else { return text }
        let kept = String(decoding: utf8[0..<maxValueBytes], as: UTF8.self)
        return kept + truncatedMarker(omittedBytes: utf8.count - maxValueBytes)
    }

    private static func boundedData(_ data: Data) -> Data {
        guard data.count > maxValueBytes else { return data }
        var kept = data.prefix(maxValueBytes)
        kept.append(contentsOf: truncatedMarker(omittedBytes: data.count - maxValueBytes).utf8)
        return kept
    }

    /// Approximate wire size of a value for the row byte budget (the Electron
    /// reference measures JSON-encoded bytes; storage size is close enough to
    /// bound memory without paying for an encode per row).
    private static func byteSize(of value: DisplayValue) -> Int {
        switch value {
        case .null: 4
        case .bool(let bool): bool ? 4 : 5
        case .number(let double): String(double).utf8.count
        case .string(let string): string.utf8.count
        case .binary(let data): data.count
        case .array(let values): values.reduce(2) { $0 + byteSize(of: $1) }
        case .object(let pairs): pairs.reduce(2) { $0 + $1.key.utf8.count + byteSize(of: $1.value) }
        }
    }

    // MARK: - Identifiers

    /// Double-quote a SQLite identifier (double quotes doubled), same rule
    /// the preview path uses. Also used by `SelectStatementBuilder`.
    public static func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Opaque object handles, same encoding as the Electron reference:
    /// `sqlite:` + base64url(JSON([kind, name])).
    static func objectID(kind: DatabaseObjectKind, name: String?) -> String {
        let payload: [Any] = name.map { [kind.rawValue, $0] } ?? [kind.rawValue, NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let base64url = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "sqlite:\(base64url)"
    }

    // MARK: - Errors

    // Opening the DatabaseQueue performs file IO, so it happens on first use
    // rather than at init (which can run on the main thread). Read-only
    // profiles open the file read-only so the SQLite layer rejects writes
    // even if the SQL classifier has a gap.
    private func currentQueue() throws -> DatabaseQueue {
        try state.withLock { state in
            if state.closed { throw AdapterError.sessionClosed }
            if let queue = state.queue { return queue }
            var configuration = Configuration()
            configuration.readonly = readOnly
            do {
                let queue = try DatabaseQueue(path: filePath, configuration: configuration)
                state.queue = queue
                return queue
            } catch {
                throw Self.sanitizedError("Could not open the SQLite database", error, filePath: filePath)
            }
        }
    }

    // SQLite errors can embed the database file path (and the query text);
    // never leak a local filesystem path to the UI.
    static func sanitizedError(_ action: String, _ error: Error, filePath: String) -> SQLiteAdapterError {
        var message = (error as? dbbbbError)?.userMessage ?? error.localizedDescription
        if !filePath.isEmpty {
            message = message.replacingOccurrences(of: filePath, with: "[local file]")
            if let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               encoded != filePath
            {
                message = message.replacingOccurrences(of: encoded, with: "[local file]")
            }
        }

        message = message
            .replacing(#/(?:[A-Za-z]:\\[\w .@+-]+)+/#) { _ in "[local file]" }
            .replacing(#/(?:\\[\w .@+-]+){2,}/#) { _ in "[local file]" }
            .replacing(#/(?:\/[\w .@+-]+){2,}/#) { _ in "[local file]" }
            .replacing(#/[\u{0}-\u{1F}\u{7F}]+/#) { _ in " " }
            .replacing(#/\s+/#) { _ in " " }
            .trimmingCharacters(in: .whitespaces)
        if message.count > maxErrorLength {
            message = String(message.prefix(maxErrorLength))
        }

        return SQLiteAdapterError("\(action): \(message.isEmpty ? "Unexpected database error." : message)")
    }
}

// MARK: - Importing

extension SQLiteAdapter: SupportsImporting {
    /// Streams a CSV file into one table. Read-only profiles are refused
    /// here (their file handle rejects writes as well). Each batch is one
    /// write transaction; values cross as text binds and SQLite's column
    /// affinity coerces them into the column's storage class.
    public func importData(_ request: ImportRequest) async throws -> ImportSummary {
        if readOnly || profile.readOnly {
            throw ImportError.unsupported(
                "SQLite import is disabled for read-only connections.")
        }
        guard request.format == .csv else {
            throw ImportError.unsupported("SQLite imports accept CSV files.")
        }
        guard request.target.kind == .table else {
            throw AdapterError.notFound("SQLite import requires a table target.")
        }
        let table = request.target.name
        let queue = try currentQueue()

        do {
            // Normal columns only: hidden (virtual-table) and generated columns
            // are excluded via table_xinfo's hidden flag.
            let columns = try await queue.read { db in
                try String.fetchAll(
                    db, sql: "SELECT name FROM pragma_table_xinfo(?) WHERE hidden = 0 ORDER BY cid",
                    arguments: [table])
            }
            guard !columns.isEmpty else {
                throw SQLiteAdapterError("SQLite import target has no insertable columns.")
            }
            guard Set(columns).count == columns.count else {
                throw SQLiteAdapterError("SQLite returned duplicate insertable-column metadata.")
            }

            return try await CSVImportDriver.run(
                fileURL: request.fileURL,
                hasHeader: request.hasHeader,
                knownColumns: columns,
                batchSize: SQLiteImportPlanner.batchSize,
                isCancelled: request.isCancelled,
                onProgress: request.onProgress,
                insertBatch: { targets, rows in
                    let sql = try SQLiteImportPlanner.insertStatement(
                        table: table, columns: targets)
                    // One write transaction per batch; a mid-batch cancellation
                    // or constraint failure rolls the whole batch back.
                    try await queue.write { db in
                        let statement = try db.makeStatement(sql: sql)
                        for row in rows {
                            if request.isCancelled() { throw ImportError.cancelled }
                            try statement.execute(arguments: StatementArguments(row))
                        }
                    }
                    return rows.count
                })
        } catch let error as ImportError {
            throw error
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("SQLite import failed", error, filePath: filePath)
        }
    }
}

// MARK: - Editing

extension SQLiteAdapter: SupportsEditing {
    /// Applies one reviewed single-row change inside one write transaction:
    /// introspect + validate the change-target metadata, plan with the pure
    /// planner, and execute the parameterized statement. `changes()` is the
    /// conflict signal: zero changed rows means the row changed or vanished
    /// underneath the edit (optimistic-concurrency conflict). Read-only
    /// sessions are refused client-side here and server-side via the
    /// `SQLITE_OPEN_READONLY` file handle.
    public func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        if readOnly || profile.readOnly {
            throw SQLiteAdapterError(
                "SQLite row changes are disabled for read-only connections.")
        }
        guard change.object.kind == .table else {
            throw AdapterError.notFound("SQLite row changes require an introspected table target.")
        }
        let table = change.object.name
        let queue = try currentQueue()
        let startedAt = Date()

        do {
            return try await queue.write { db in
                let metadataRows = try Row.fetchAll(
                    db, sql: SQLiteChangePlanner.listTableChangeColumnsSQL, arguments: [table])
                let metadata = try SQLiteChangePlanner.changeTableMetadata(
                    rows: metadataRows.map { row in
                        (name: row["name"] as String,
                         declaredType: row["type"] as String,
                         primaryKeyOrdinal: row["pk"] as Int)
                    })

                let plan: SQLiteParameterizedPlan
                let bindColumns: [String]
                switch change.operation {
                case .insert(let values):
                    // No optimistic lock for a row that does not exist yet; the
                    // reviewed values are catalog-ordered like the original patch.
                    let entries = try SQLiteChangeMapper.orderedEntries(
                        values, metadata: metadata, label: "SQLite insert values")
                    plan = try SQLiteChangePlanner.planInsert(table: table, entries: entries)
                    bindColumns = entries.map(\.column)
                case .update, .delete:
                    let original = try SQLiteChangeMapper.orderedEntries(
                        change.original, metadata: metadata, label: "SQLite original values")
                    let current: [SQLiteFieldEntry]?
                    if case .update(let changed) = change.operation {
                        current = try SQLiteChangeMapper.currentEntries(
                            original: original, changed: changed)
                    } else {
                        current = nil
                    }
                    let primaryKey = try SQLiteChangeMapper.primaryKeyEntries(
                        metadata: metadata, original: original)
                    if let current {
                        plan = try SQLiteChangePlanner.planUpdate(
                            table: table, columnTypes: metadata.columnTypes,
                            primaryKey: primaryKey, original: original, current: current)
                    } else {
                        plan = try SQLiteChangePlanner.planDelete(
                            table: table, columnTypes: metadata.columnTypes,
                            primaryKey: primaryKey, original: original)
                    }
                    bindColumns = SQLiteChangeMapper.bindColumns(
                        primaryKey: primaryKey, original: original, current: current)
                }
                guard bindColumns.count == plan.values.count else {
                    throw SQLiteAdapterError("SQLite change planning failed.")
                }
                let binds = try zip(bindColumns, plan.values).map { column, value in
                    try SQLiteChangeMapper.bind(
                        for: value, columnType: metadata.columnTypes[column], label: column)
                }

                try db.execute(sql: plan.text, arguments: StatementArguments(binds))
                guard db.changesCount > 0 else {
                    throw SQLiteAdapterError(
                        "SQLite optimistic-concurrency conflict: "
                            + "the row changed or no longer exists.")
                }
                guard db.changesCount == 1 else {
                    throw SQLiteAdapterError(
                        "SQLite refused a row change with an unexpected affected-row count.")
                }

                let elapsed = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
                return .rows(
                    columns: [],
                    rows: [],
                    meta: ResultMeta(count: 1, truncated: false, elapsedMilliseconds: elapsed))
            }
        } catch let error as SQLiteChangePlanError {
            throw error
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("SQLite data change failed", error, filePath: filePath)
        }
    }

    /// Insertable columns for building insert drafts — the same introspection
    /// and validation as `applyDataChange` (hidden/generated columns
    /// excluded). Reading metadata is a read: read-only profiles still allow it.
    public func insertableColumns(for object: DatabaseObject) async throws -> [InsertableColumn] {
        guard object.kind == .table else {
            throw AdapterError.notFound("SQLite insert drafts require an introspected table target.")
        }
        let table = object.name
        let queue = try currentQueue()
        do {
            return try await queue.read { db in
                let metadataRows = try Row.fetchAll(
                    db, sql: SQLiteChangePlanner.listTableChangeColumnsSQL, arguments: [table])
                let metadata = try SQLiteChangePlanner.changeTableMetadata(
                    rows: metadataRows.map { row in
                        (name: row["name"] as String,
                         declaredType: row["type"] as String,
                         primaryKeyOrdinal: row["pk"] as Int)
                    })
                let ordinals = Dictionary(
                    metadata.primaryKey.enumerated().map { ($0.element, $0.offset + 1) }) { first, _ in first }
                return metadata.columns.map {
                    InsertableColumn(name: $0, primaryKeyOrdinal: ordinals[$0] ?? 0)
                }
            }
        } catch let error as SQLiteChangePlanError {
            throw error
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not read the SQLite table columns", error, filePath: filePath)
        }
    }
}


// MARK: - Introspection

extension SQLiteAdapter: SupportsIntrospection {
    /// sqlite_master stores the original CREATE text verbatim; the name
    /// lookup is parameterized so unusual identifiers stay safe. `sql` is
    /// NULL for internal objects (auto-indexes), which the object list never
    /// surfaces. Reading DDL is a read: allowed on read-only profiles.
    private static let createStatementSQL = """
        SELECT sql
        FROM sqlite_master
        WHERE name = ?
          AND type IN ('table', 'view')
        """

    public func createStatement(for object: DatabaseObject) async throws -> String {
        guard object.kind == .table || object.kind == .view else {
            throw AdapterError.notFound("SQLite create statements require a table or view target.")
        }
        let queue = try currentQueue()
        do {
            return try await queue.read { db in
                guard let ddl = try String.fetchOne(
                    db, sql: Self.createStatementSQL, arguments: [object.name]),
                    !ddl.isEmpty
                else {
                    throw AdapterError.notFound("This SQLite object has no stored create statement.")
                }
                return ddl
            }
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError(
                "Could not read the SQLite create statement", error, filePath: filePath)
        }
    }
}

// MARK: - Foreign keys

extension SQLiteAdapter: SupportsForeignKeys {
    /// Foreign keys of one introspected table (ROADMAP M1 ⑤), grouped by
    /// constraint id in column order. The table name crosses as a bound
    /// argument to the table-valued pragma. `REFERENCES t` without a column
    /// list reports a NULL target column; those are resolved through the
    /// referenced table's primary key. Reading metadata is a read: read-only
    /// profiles still allow it.
    public func foreignKeys(for object: DatabaseObject) async throws -> [dbbbbCore.ForeignKey] {
        guard object.kind == .table else {
            throw AdapterError.notFound("SQLite foreign keys require an introspected table target.")
        }
        return try await foreignKeys(named: object.name)
    }

    /// The shared per-table foreign-key read behind `foreignKeys(for:)` and
    /// the database-wide `allForeignKeys()`.
    private func foreignKeys(named tableName: String) async throws -> [dbbbbCore.ForeignKey] {
        let queue = try currentQueue()
        do {
            return try await queue.read { db in
                let rows = try Row.fetchAll(
                    db, sql: SQLiteForeignKeyPlanner.listForeignKeysSQL,
                    arguments: [tableName])
                var parsed: [(id: Int, column: String, referencedTable: String,
                              referencedColumn: String?)] = []
                var implicitTables: Set<String> = []
                for row in rows {
                    guard let id: Int = row["id"], let column: String = row["from"],
                          let referencedTable: String = row["table"]
                    else {
                        throw SQLiteAdapterError("SQLite returned invalid foreign-key metadata.")
                    }
                    let referencedColumn: String? = row["to"]
                    if referencedColumn == nil { implicitTables.insert(referencedTable) }
                    parsed.append((id, column, referencedTable, referencedColumn))
                }
                var implicitColumns: [String: [String]] = [:]
                for table in implicitTables {
                    implicitColumns[table] = try String.fetchAll(
                        db, sql: SQLiteForeignKeyPlanner.implicitReferencedColumnsSQL,
                        arguments: [table])
                }
                return try SQLiteForeignKeyPlanner.foreignKeys(
                    rows: parsed, implicitColumns: implicitColumns)
            }
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not read the SQLite foreign keys", error, filePath: filePath)
        }
    }
}

// MARK: - Table statistics

extension SQLiteAdapter: SupportsTableStatistics {
    /// SQLite has no planner estimates: `COUNT(*)` is the only truthful
    /// count (ROADMAP M2 ⑩). It runs through the normal query path, so the
    /// timeout watchdog and `cancel(requestID:)` interrupt it exactly like
    /// user SQL. Sizes are file-level — `page_count × page_size` covers the
    /// whole database file (per-object sizes need the optional dbstat vtab,
    /// which is not guaranteed), and the sheet says so through `extras`.
    /// Views report rows only. Reading statistics is a read: read-only
    /// profiles still allow it.
    public func tableStatistics(for object: DatabaseObject) async throws -> TableStatistics {
        guard object.kind == .table || object.kind == .view else {
            throw AdapterError.notFound("SQLite statistics require a table or view target.")
        }
        let countSQL = "SELECT COUNT(*) FROM \(SQLiteAdapter.quoteIdentifier(object.name))"
        let counted = try await runQuery(
            sql: countSQL, binds: [], options: ExecuteOptions(maxRows: 1))
        guard case .rows(_, let rows, _) = counted,
              let row = rows.first, let countCell = row.first
        else {
            throw SQLiteAdapterError("SQLite returned invalid statistics metadata.")
        }
        let estimatedRows: Int64?
        switch countCell {
        case .number(let value) where value.isFinite && value >= 0 && value <= Double(Int64.max):
            estimatedRows = Int64(value)
        default:
            estimatedRows = nil
        }
        guard object.kind == .table else {
            return TableStatistics(estimatedRows: estimatedRows)
        }
        let queue = try currentQueue()
        do {
            return try await queue.read { db in
                let pageCount = try Int64.fetchOne(db, sql: "PRAGMA page_count") ?? 0
                let pageSize = try Int64.fetchOne(db, sql: "PRAGMA page_size") ?? 0
                let (totalBytes, overflow) = pageCount.multipliedReportingOverflow(by: pageSize)
                return TableStatistics(
                    estimatedRows: estimatedRows,
                    totalBytes: overflow ? nil : totalBytes,
                    indexBytes: nil,
                    extras: [TableStatistics.Entry(
                        name: "Size scope", value: "Whole database file")])
            }
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not read the SQLite statistics", error, filePath: filePath)
        }
    }
}

// MARK: - Schema introspection

extension SQLiteAdapter: SupportsSchemaIntrospection {
    /// Structured schema of one table or view: columns with nullability and
    /// primary-key ordinals (`pragma_table_info`), indexes
    /// (`pragma_index_list` + `pragma_index_info` per index), and foreign
    /// keys (tables only — views have none). Reading metadata is a read:
    /// read-only profiles still allow it.
    public func schema(for object: DatabaseObject) async throws -> dbbbbCore.TableSchema {
        guard object.kind == .table || object.kind == .view else {
            throw AdapterError.notFound("SQLite schemas require a table or view target.")
        }
        let queue = try currentQueue()
        do {
            let (columns, indexes) = try await queue.read { db in
                let columnRows = try Row.fetchAll(
                    db, sql: SQLiteSchemaPlanner.listColumnsSQL,
                    arguments: [object.name])
                var parsedColumns: [(name: String, dataType: String, notNull: Bool,
                                     primaryKeyOrdinal: Int)] = []
                for row in columnRows {
                    guard let name: String = row["name"],
                          let dataType: String = row["type"],
                          let notNull: Int = row["notnull"],
                          let ordinal: Int = row["pk"]
                    else {
                        throw SQLiteAdapterError("SQLite returned invalid schema metadata.")
                    }
                    parsedColumns.append((name, dataType, notNull != 0, ordinal))
                }
                let columns = try SQLiteSchemaPlanner.columns(rows: parsedColumns)

                let indexRows = try Row.fetchAll(
                    db, sql: SQLiteSchemaPlanner.listIndexesSQL,
                    arguments: [object.name])
                var parsedIndexes: [(name: String, isUnique: Bool)] = []
                for row in indexRows {
                    guard let name: String = row["name"],
                          let unique: Int = row["unique"]
                    else {
                        throw SQLiteAdapterError("SQLite returned invalid schema metadata.")
                    }
                    parsedIndexes.append((name, unique != 0))
                }
                var indexColumns: [String: [String]] = [:]
                for index in parsedIndexes {
                    indexColumns[index.name] = try String.fetchAll(
                        db, sql: SQLiteSchemaPlanner.listIndexColumnsSQL,
                        arguments: [index.name])
                }
                let indexes = try SQLiteSchemaPlanner.indexes(
                    rows: parsedIndexes, columns: indexColumns)
                return (columns, indexes)
            }
            let keys: [dbbbbCore.ForeignKey] =
                object.kind == .table ? try await foreignKeys(for: object) : []
            return dbbbbCore.TableSchema(
                object: object, columns: columns, foreignKeys: keys, indexes: indexes)
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not read the SQLite schema", error, filePath: filePath)
        }
    }

    /// Every foreign-key edge of the database file, one per user table,
    /// reusing the per-table read (implicit-PK references resolved). Reading
    /// metadata is a read: read-only profiles still allow it.
    public func allForeignKeys() async throws -> [dbbbbCore.TableRelation] {
        let queue = try currentQueue()
        do {
            let tables = try await queue.read { db in
                try String.fetchAll(db, sql: SQLiteSchemaPlanner.listTablesSQL)
            }
            var relations: [dbbbbCore.TableRelation] = []
            for table in tables {
                let keys = try await foreignKeys(named: table)
                let object = DatabaseObject(
                    id: SQLiteAdapter.objectID(kind: .table, name: table),
                    parentID: SQLiteAdapter.objectID(kind: .schema, name: nil),
                    name: table,
                    kind: .table)
                relations.append(contentsOf: keys.map {
                    dbbbbCore.TableRelation(object: object, foreignKey: $0)
                })
            }
            return relations
        } catch let error as SQLiteAdapterError {
            throw error
        } catch let error as AdapterError {
            throw error
        } catch {
            throw Self.sanitizedError("Could not read the SQLite foreign keys", error, filePath: filePath)
        }
    }
}
