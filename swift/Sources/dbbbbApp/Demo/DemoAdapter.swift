import Foundation
import dbbbbCore
import dbbbbKit

/// Rejected-statement error for the demo engine; message is already redacted.
enum DemoError: dbbbbError {
    case statementRejected

    var userMessage: String {
        "The demo engine rejected the statement (no real server is attached)."
    }
}

/// In-memory adapter that drives every UI path until the real engine adapters land.
/// Actor-isolated, so it satisfies `DatabaseAdapter`'s `Sendable` requirement for free.
///
/// BullMQ demo sessions delegate to a real `BullmqAdapter` embedded over an
/// in-memory Redis (`DemoRedisClient`), so paging, filters, logs, and
/// snapshots exercise the production code path instead of canned shortcuts.
actor DemoAdapter: DatabaseAdapter {
    nonisolated let profile: ConnectionProfile
    private let fixture: DemoFixture
    private var cancelledRequests: Set<UUID> = []
    private let bullmqAdapter: BullmqAdapter?
    private var bullmqConnected = false

    init(profile: ConnectionProfile, fixture: DemoFixture) {
        self.profile = profile
        self.fixture = fixture
        if profile.engine == .bullmq {
            // Fixed, known-valid demo input; the client is in-memory.
            let client = DemoRedisClient.seeded()
            self.bullmqAdapter = try! BullmqAdapter(
                input: ConnectionInput.BullmqInput(
                    name: profile.name, host: "demo", database: 0, prefix: "bull",
                    environment: profile.environment, readOnly: profile.readOnly),
                client: client, fetcher: BullmqJsPageFetcher(client: client))
        } else {
            self.bullmqAdapter = nil
        }
    }

    /// A "new connection" in demo mode gets the canned dataset for its engine.
    init(input: ConnectionInput) {
        self.init(
            profile: ConnectionProfile(
                id: Self.demoID(for: input.engine),
                name: input.name,
                engine: input.engine,
                endpoint: input.endpoint,
                database: input.database,
                environment: input.environment,
                readOnly: input.readOnly,
                demo: true
            ),
            fixture: .fixture(for: input.engine)
        )
    }

    /// Stable per-engine demo ids: "removed demo connection" preferences key
    /// off these across launches. Demo ids were random per launch before the
    /// removal preference existed, so nothing persisted can meaningfully
    /// reference the old ones.
    static func demoID(for engine: DatabaseEngine) -> UUID {
        switch engine {
        case .postgresql: UUID(uuidString: "00000000-0000-0000-0000-00000000de01")!
        case .mongodb: UUID(uuidString: "00000000-0000-0000-0000-00000000de02")!
        case .mysql: UUID(uuidString: "00000000-0000-0000-0000-00000000de03")!
        case .sqlite: UUID(uuidString: "00000000-0000-0000-0000-00000000de04")!
        case .bullmq: UUID(uuidString: "00000000-0000-0000-0000-00000000de05")!
        }
    }

    /// The seeded demo connections, one per engine.
    static func demoSessions() -> [DemoAdapter] {
        [
            DemoAdapter(
                profile: ConnectionProfile(
                    id: demoID(for: .postgresql),
                    name: "Warehouse (PG)", engine: .postgresql,
                    endpoint: "db.internal:5432", database: "warehouse",
                    environment: .production, readOnly: true, demo: true),
                fixture: .postgres),
            DemoAdapter(
                profile: ConnectionProfile(
                    id: demoID(for: .mongodb),
                    name: "Events (Mongo)", engine: .mongodb,
                    endpoint: "mongodb://***/analytics", database: "analytics",
                    environment: .staging, readOnly: false, demo: true),
                fixture: .mongo),
            DemoAdapter(
                profile: ConnectionProfile(
                    id: demoID(for: .mysql),
                    name: "Shop (MySQL)", engine: .mysql,
                    endpoint: "127.0.0.1:3306", database: "shop",
                    environment: .development, readOnly: false, demo: true),
                fixture: .mysql),
            DemoAdapter(
                profile: ConnectionProfile(
                    id: demoID(for: .sqlite),
                    name: "Local Notes (SQLite)", engine: .sqlite,
                    endpoint: "notes.db", database: "notes.db",
                    environment: .development, readOnly: false, demo: true),
                fixture: .sqlite),
            DemoAdapter(
                profile: ConnectionProfile(
                    id: demoID(for: .bullmq),
                    name: "Local Queues (BullMQ)", engine: .bullmq,
                    endpoint: "demo:6379", database: "0",
                    environment: .development, readOnly: true, demo: true),
                fixture: .empty),
        ]
    }

    /// The embedded BullMQ adapter, connected once on first use.
    private func bullmq() async throws -> BullmqAdapter? {
        guard let bullmqAdapter else { return nil }
        if !bullmqConnected {
            try await bullmqAdapter.connect()
            bullmqConnected = true
        }
        return bullmqAdapter
    }

    func listObjects() async throws -> [DatabaseObject] {
        if let bullmq = try await bullmq() { return try await bullmq.listObjects() }
        try await simulateLatency(milliseconds: 220)
        return fixture.objects
    }

    /// Paged/sorted/filtered preview over the canned fixture, mirroring the
    /// real adapters: the filter is a case-insensitive substring match on the
    /// cell's display text, the sort a total order over display values
    /// (numbers numerically, strings lexically, NULLs low), and the page is
    /// sliced after both. `truncated` signals that a next page exists.
    func previewObject(_ request: PreviewRequest) async throws -> QueryResult {
        if let bullmq = try await bullmq() { return try await bullmq.previewObject(request) }
        let start = ContinuousClock.now
        try await simulateLatency(milliseconds: 180, cancelling: request.requestID)
        let elapsed = milliseconds(since: start)
        let offset = request.normalizedOffset
        let limit = request.normalizedLimit
        if let table = fixture.tables.first(where: { $0.object.id == request.object.id }) {
            let rows = Self.arrange(
                table.rows, columns: table.columns, sort: request.sort,
                filter: request.filter, equalities: request.equalities)
            let page = Array(rows.dropFirst(offset).prefix(limit))
            return .rows(columns: table.columns, rows: page,
                         meta: ResultMeta(count: page.count, truncated: rows.count > offset + page.count, elapsedMilliseconds: elapsed))
        }
        if let collection = fixture.collections.first(where: { $0.object.id == request.object.id }) {
            let documents = Self.arrange(collection.documents, sort: request.sort, filter: request.filter)
            let page = Array(documents.dropFirst(offset).prefix(limit))
            return .documents(page,
                              meta: ResultMeta(count: page.count, truncated: documents.count > offset + page.count, elapsedMilliseconds: elapsed))
        }
        throw AdapterError.notFound("Unknown object.")
    }

    /// Demo grid filter + sort for row results (contains on the cell's display
    /// text; equalities match the exact display value; unknown columns leave
    /// the page untouched).
    private static func arrange(
        _ rows: [[DisplayValue]],
        columns: [ColumnMeta],
        sort: PreviewRequest.Sort?,
        filter: PreviewRequest.Filter?,
        equalities: [PreviewRequest.Equality] = []
    ) -> [[DisplayValue]] {
        var result = rows
        if let filter,
           let index = columns.firstIndex(where: { $0.name == filter.column }),
           !filter.contains.isEmpty {
            result = result.filter { row in
                index < row.count && displayText(row[index]).localizedCaseInsensitiveContains(filter.contains)
            }
        }
        for equality in equalities {
            guard let index = columns.firstIndex(where: { $0.name == equality.column }) else { continue }
            result = result.filter { row in index < row.count && row[index] == equality.value }
        }
        if let sort,
           let index = columns.firstIndex(where: { $0.name == sort.column }) {
            result = result.sorted { lhs, rhs in
                guard index < lhs.count, index < rhs.count else { return false }
                let order = compare(lhs[index], rhs[index])
                return sort.ascending ? order < 0 : order > 0
            }
        }
        return result
    }

    /// Same for MongoDB document results: the column is a top-level key.
    private static func arrange(
        _ documents: [DisplayValue],
        sort: PreviewRequest.Sort?,
        filter: PreviewRequest.Filter?
    ) -> [DisplayValue] {
        func field(_ key: String, of document: DisplayValue) -> DisplayValue? {
            guard case .object(let pairs) = document else { return nil }
            return pairs.first(where: { $0.key == key })?.value
        }
        var result = documents
        if let filter, !filter.contains.isEmpty {
            result = result.filter { document in
                field(filter.column, of: document)
                    .map { displayText($0).localizedCaseInsensitiveContains(filter.contains) } ?? false
            }
        }
        if let sort {
            result = result.sorted { lhs, rhs in
                let order = compare(field(sort.column, of: lhs) ?? .null, field(sort.column, of: rhs) ?? .null)
                return sort.ascending ? order < 0 : order > 0
            }
        }
        return result
    }

    /// Display text for the demo filter; matches what the grid shows.
    private static func displayText(_ value: DisplayValue) -> String {
        switch value {
        case .null: ""
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number): String(number)
        case .string(let text): text
        case .binary(let data): "\(data.count) bytes"
        case .array, .object: String(describing: value)
        }
    }

    /// Total order over display values for the demo sort: NULLs low, then
    /// numbers numerically, bools, strings, everything else by display text.
    private static func compare(_ lhs: DisplayValue, _ rhs: DisplayValue) -> Int {
        func rank(_ value: DisplayValue) -> Int {
            switch value {
            case .null: 0
            case .number: 1
            case .bool: 2
            case .string: 3
            case .binary, .array, .object: 4
            }
        }
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        guard lhsRank == rhsRank else { return lhsRank - rhsRank }
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)): return a == b ? 0 : (a < b ? -1 : 1)
        case (.bool(let a), .bool(let b)): return a == b ? 0 : (a ? 1 : -1)
        default:
            let a = displayText(lhs)
            let b = displayText(rhs)
            return a == b ? 0 : (a < b ? -1 : 1)
        }
    }

    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        if profile.engine == .bullmq {
            guard case .bullmqJobs = command else { throw AdapterError.engineMismatch }
            guard let bullmq = try await bullmq() else { throw AdapterError.engineMismatch }
            return try await bullmq.execute(command, options: options)
        }
        let start = ContinuousClock.now
        try await simulateLatency(milliseconds: 420, cancelling: options.requestID)
        let elapsed = milliseconds(since: start)
        if profile.engine.isSQLFamily {
            guard case .sql(let text) = command else { throw AdapterError.engineMismatch }
            return try executeSQL(text, options: options, elapsed: elapsed)
        }
        switch command {
        case .mongoFind(let collection, let filter):
            return try executeMongo(collection: collection, text: filter, options: options, elapsed: elapsed)
        case .mongoAggregate(let collection, let pipeline):
            return try executeMongo(collection: collection, text: pipeline, options: options, elapsed: elapsed)
        case .sql, .bullmqJobs: throw AdapterError.engineMismatch
        }
    }

    func cancel(requestID: UUID) async throws {
        if let bullmq = try await bullmq() {
            try await bullmq.cancel(requestID: requestID)
            return
        }
        // SQLite has no server-side interruption; demo the unsupported path there.
        if profile.engine == .sqlite { throw AdapterError.cancellationUnsupported }
        cancelledRequests.insert(requestID)
    }

    func close() async {
        if let bullmqAdapter { await bullmqAdapter.close() }
        cancelledRequests.removeAll()
    }

    // MARK: Internals

    private static let writeVerbs = ["insert", "update", "delete", "drop", "alter", "truncate", "create", "grant", "replace"]

    private func executeSQL(_ text: String, options: ExecuteOptions, elapsed: Int) throws -> QueryResult {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.writeVerbs.contains(where: { lowered.hasPrefix($0) }) {
            if profile.readOnly { throw AdapterError.readOnlyViolation }
            return .rows(columns: [], rows: [],
                         meta: ResultMeta(count: 0, truncated: false, elapsedMilliseconds: elapsed))
        }
        if lowered.contains("raise_error") { throw DemoError.statementRejected }
        guard let table = fixture.tables.first(where: { lowered.contains($0.object.name.lowercased()) }) else {
            let names = fixture.tables.map(\.object.name).joined(separator: ", ")
            throw AdapterError.notFound("No demo table matches that name. Try: \(names).")
        }
        let returned = Array(table.rows.prefix(options.maxRows))
        return .rows(columns: table.columns, rows: returned,
                     meta: ResultMeta(count: returned.count, truncated: table.rows.count > returned.count, elapsedMilliseconds: elapsed))
    }

    private func executeMongo(collection: String, text: String, options: ExecuteOptions, elapsed: Int) throws -> QueryResult {
        if text.lowercased().contains("raise_error") { throw DemoError.statementRejected }
        let target = fixture.collections.first { $0.object.name == collection }
            ?? fixture.collections.first { text.localizedCaseInsensitiveContains($0.object.name) }
            ?? fixture.collections.first
        guard let target else { throw AdapterError.notFound("This demo database has no collections.") }
        let returned = Array(target.documents.prefix(options.maxRows))
        return .documents(returned,
                          meta: ResultMeta(count: returned.count, truncated: target.documents.count > returned.count, elapsedMilliseconds: elapsed))
    }

    private func simulateLatency(milliseconds: Int, cancelling requestID: UUID? = nil) async throws {
        let chunks = 8
        for _ in 0..<chunks {
            try await Task.sleep(for: .milliseconds(milliseconds / chunks))
            if Task.isCancelled || (requestID.map { cancelledRequests.contains($0) } ?? false) {
                if let requestID { cancelledRequests.remove(requestID) }
                throw CancellationError()
            }
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}

// MARK: - Demo explain & statistics (ROADMAP M2 ⑧⑩)

extension DemoAdapter: SupportsExplain {
    /// Canned query-plan document — the demo engine has no real planner.
    func explain(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        let start = ContinuousClock.now
        try await simulateLatency(milliseconds: 200, cancelling: options.requestID)
        let plan: DisplayValue = .object([
            ("stage", .string("DEMO_SCAN")),
            ("query", .string(command.text)),
            ("note", .string("The demo engine has no real planner; this is a canned plan.")),
        ])
        return .documents([plan], meta: ResultMeta(
            count: 1, truncated: false, elapsedMilliseconds: milliseconds(since: start)))
    }
}

extension DemoAdapter: SupportsTableStatistics {
    /// Fixture numbers, derived from the canned dataset's actual sizes.
    func tableStatistics(for object: DatabaseObject) async throws -> TableStatistics {
        try await simulateLatency(milliseconds: 120)
        if let table = fixture.tables.first(where: { $0.object.id == object.id }) {
            return TableStatistics(
                estimatedRows: Int64(table.rows.count),
                totalBytes: Int64(table.rows.count) * 512,
                indexBytes: Int64(table.rows.count) * 64)
        }
        if let collection = fixture.collections.first(where: { $0.object.id == object.id }) {
            return TableStatistics(
                estimatedRows: Int64(collection.documents.count),
                totalBytes: Int64(collection.documents.count) * 1024,
                indexBytes: Int64(collection.documents.count) * 128,
                extras: [TableStatistics.Entry(
                    name: "Data size (uncompressed)",
                    value: "\(collection.documents.count * 2048) bytes")])
        }
        throw AdapterError.notFound("Unknown object.")
    }
}

// MARK: - Demo server activity (ROADMAP M2 ⑨)

extension DemoAdapter: SupportsServerActivity {
    /// Canned activity rows from the fixture. Listing is a read; even the
    /// read-only demo warehouse may list.
    func listActivity() async throws -> [ServerActivity] {
        try await simulateLatency(milliseconds: 120)
        return fixture.activities
    }

    /// Demo kill is a no-op — there is no real server behind a demo
    /// connection, and the session layer never offers kill for demo profiles.
    func killActivity(id: String) async throws {
        try await simulateLatency(milliseconds: 80)
    }
}

// MARK: - Demo BullMQ snapshots (Sync to local SQL)

extension DemoAdapter: SupportsBullmqSnapshot {
    /// Delegates to the embedded BullMQ adapter; fail closed on other engines.
    func collectBullmqJobs(
        options: BullmqCollectOptions,
        onBatch: @Sendable ([DisplayValue]) async throws -> Void
    ) async throws -> Int {
        guard let bullmq = try await bullmq() else { throw AdapterError.engineMismatch }
        return try await bullmq.collectBullmqJobs(options: options, onBatch: onBatch)
    }
}
