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
actor DemoAdapter: DatabaseAdapter {
    nonisolated let profile: ConnectionProfile
    private let fixture: DemoFixture
    private var cancelledRequests: Set<UUID> = []

    init(profile: ConnectionProfile, fixture: DemoFixture) {
        self.profile = profile
        self.fixture = fixture
    }

    /// A "new connection" in demo mode gets the canned dataset for its engine.
    init(input: ConnectionInput) {
        self.init(
            profile: ConnectionProfile(
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

    /// The four seeded demo connections, one per engine.
    static func demoSessions() -> [DemoAdapter] {
        [
            DemoAdapter(
                profile: ConnectionProfile(
                    name: "Warehouse (PG)", engine: .postgresql,
                    endpoint: "db.internal:5432", database: "warehouse",
                    environment: .production, readOnly: true, demo: true),
                fixture: .postgres),
            DemoAdapter(
                profile: ConnectionProfile(
                    name: "Events (Mongo)", engine: .mongodb,
                    endpoint: "mongodb://***/analytics", database: "analytics",
                    environment: .staging, readOnly: false, demo: true),
                fixture: .mongo),
            DemoAdapter(
                profile: ConnectionProfile(
                    name: "Shop (MySQL)", engine: .mysql,
                    endpoint: "127.0.0.1:3306", database: "shop",
                    environment: .development, readOnly: false, demo: true),
                fixture: .mysql),
            DemoAdapter(
                profile: ConnectionProfile(
                    name: "Local Notes (SQLite)", engine: .sqlite,
                    endpoint: "notes.db", database: "notes.db",
                    environment: .development, readOnly: false, demo: true),
                fixture: .sqlite),
        ]
    }

    func listObjects() async throws -> [DatabaseObject] {
        try await simulateLatency(milliseconds: 220)
        return fixture.objects
    }

    func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        let start = ContinuousClock.now
        try await simulateLatency(milliseconds: 180)
        let elapsed = milliseconds(since: start)
        if let table = fixture.tables.first(where: { $0.object.id == object.id }) {
            let cap = min(100, table.rows.count)
            return .rows(columns: table.columns, rows: Array(table.rows.prefix(cap)),
                         meta: ResultMeta(count: cap, truncated: table.rows.count > cap, elapsedMilliseconds: elapsed))
        }
        if let collection = fixture.collections.first(where: { $0.object.id == object.id }) {
            let cap = min(100, collection.documents.count)
            return .documents(Array(collection.documents.prefix(cap)),
                              meta: ResultMeta(count: cap, truncated: collection.documents.count > cap, elapsedMilliseconds: elapsed))
        }
        throw AdapterError.notFound("Unknown object.")
    }

    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
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
        case .sql: throw AdapterError.engineMismatch
        }
    }

    func cancel(requestID: UUID) async throws {
        // SQLite has no server-side interruption; demo the unsupported path there.
        if profile.engine == .sqlite { throw AdapterError.cancellationUnsupported }
        cancelledRequests.insert(requestID)
    }

    func close() async {
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
