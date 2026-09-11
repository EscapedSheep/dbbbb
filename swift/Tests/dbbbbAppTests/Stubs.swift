import Foundation
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Configurable adapter double: delays and injected errors drive the
/// SessionStore state machine through every completion path.
class StubAdapter: DatabaseAdapter, @unchecked Sendable {
    let profile: ConnectionProfile
    let lock = NSLock()
    var objects: [DatabaseObject] = []
    var listObjectsDelay: Duration = .zero
    var previewDelay: Duration = .zero
    var previewError: (any Error)?
    var executeDelay: Duration = .zero
    var executeError: (any Error)?
    private var cancelled: [UUID] = []
    private var closed = false
    private var executed: [DatabaseCommand] = []
    private var previews: [PreviewRequest] = []
    /// Controls the `truncated` flag of the canned preview result, so tests can
    /// drive the "has next page" state machine.
    var previewTruncated = false

    var cancelledRequestIDs: [UUID] { lock.withLock { cancelled } }
    var wasClosed: Bool { lock.withLock { closed } }
    var executedCommands: [DatabaseCommand] { lock.withLock { executed } }
    var previewRequests: [PreviewRequest] { lock.withLock { previews } }

    init(engine: DatabaseEngine = .sqlite, readOnly: Bool = false, demo: Bool = false, name: String = "Stub") {
        profile = ConnectionProfile(
            name: name, engine: engine, endpoint: "stub", database: "stub",
            environment: .development, readOnly: readOnly, demo: demo)
    }

    func listObjects() async throws -> [DatabaseObject] {
        if listObjectsDelay > .zero { try await Task.sleep(for: listObjectsDelay) }
        return objects
    }

    func previewObject(_ request: PreviewRequest) async throws -> QueryResult {
        lock.withLock { previews.append(request) }
        if previewDelay > .zero { try await Task.sleep(for: previewDelay) }
        try Task.checkCancellation()
        if let previewError { throw previewError }
        return Self.rowsResult(truncated: lock.withLock { previewTruncated })
    }

    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        lock.withLock { executed.append(command) }
        if executeDelay > .zero { try await Task.sleep(for: executeDelay) }
        try Task.checkCancellation()
        if let executeError { throw executeError }
        return Self.rowsResult
    }

    func cancel(requestID: UUID) async throws {
        lock.withLock { cancelled.append(requestID) }
    }

    func close() async {
        lock.withLock { closed = true }
    }

    static var rowsResult: QueryResult {
        rowsResult(truncated: false)
    }

    static func rowsResult(truncated: Bool) -> QueryResult {
        .rows(columns: [ColumnMeta(name: "id", typeName: "int", numeric: true)],
              rows: [[.number(1)]],
              meta: ResultMeta(count: 1, truncated: truncated, elapsedMilliseconds: 1))
    }

    static let table = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
    static let otherTable = DatabaseObject(id: "t2", parentID: nil, name: "orders", kind: .table)
    static let collection = DatabaseObject(id: "c1", parentID: nil, name: "events", kind: .collection)
    static let schema = DatabaseObject(id: "s1", parentID: nil, name: "main", kind: .schema)
}

final class IntrospectingStubAdapter: StubAdapter, SupportsIntrospection, @unchecked Sendable {
    var ddl = "CREATE TABLE items (id INTEGER PRIMARY KEY);"
    var introspectionError: (any Error)?
    private var introspected: [DatabaseObject] = []

    var introspectedObjects: [DatabaseObject] { lock.withLock { introspected } }

    func createStatement(for object: DatabaseObject) async throws -> String {
        lock.withLock { introspected.append(object) }
        if let introspectionError { throw introspectionError }
        return ddl
    }
}

final class EditingStubAdapter: StubAdapter, SupportsEditing, @unchecked Sendable {
    var applyDelay: Duration = .zero
    var applyError: (any Error)?
    /// When non-empty, each apply consumes the next entry instead of the
    /// blanket `applyError`: nil = success, an error = throw. Drives the
    /// batch stop-at-first-failure tests.
    var applyErrorSequence: [(any Error)?] = []
    var insertableColumnResult: [InsertableColumn] = [
        InsertableColumn(name: "id", primaryKeyOrdinal: 1),
        InsertableColumn(name: "name", primaryKeyOrdinal: 0),
    ]
    var insertableColumnsError: (any Error)?
    private var appliedChanges: [DataChange] = []

    var applied: [DataChange] { lock.withLock { appliedChanges } }

    func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        // A queued sequence entry (success or failure) takes precedence over
        // the blanket error: outer nil = no sequence left, .some(nil) =
        // success, .some(error) = throw.
        let entry: (any Error)?? = lock.withLock {
            applyErrorSequence.isEmpty ? nil : .some(applyErrorSequence.removeFirst())
        }
        if let entry {
            if let error = entry { throw error }
            lock.withLock { appliedChanges.append(change) }
            return Self.rowsResult
        }
        lock.withLock { appliedChanges.append(change) }
        if applyDelay > .zero { try await Task.sleep(for: applyDelay) }
        try Task.checkCancellation()
        if let applyError { throw applyError }
        return Self.rowsResult
    }

    func insertableColumns(for object: DatabaseObject) async throws -> [InsertableColumn] {
        if let insertableColumnsError { throw insertableColumnsError }
        return insertableColumnResult
    }
}

final class ForeignKeysStubAdapter: StubAdapter, SupportsForeignKeys, @unchecked Sendable {
    var foreignKeyResult: [ForeignKey] = []
    var foreignKeysError: (any Error)?
    private var introspected: [DatabaseObject] = []

    var foreignKeyRequests: [DatabaseObject] { lock.withLock { introspected } }

    func foreignKeys(for object: DatabaseObject) async throws -> [ForeignKey] {
        lock.withLock { introspected.append(object) }
        if let foreignKeysError { throw foreignKeysError }
        return lock.withLock { foreignKeyResult }
    }
}

final class ImportingStubAdapter: StubAdapter, SupportsImporting, @unchecked Sendable {
    var importDelay: Duration = .zero
    var importError: (any Error)?
    var progressEvents: [ImportProgress] = []
    private var importCalls = 0

    var importCallCount: Int { lock.withLock { importCalls } }

    func importData(_ request: ImportRequest) async throws -> ImportSummary {
        lock.withLock { importCalls += 1 }
        for event in progressEvents { request.onProgress(event) }
        var remaining = importDelay
        while remaining > .zero {
            if request.isCancelled() { throw ImportError.cancelled }
            let chunk = min(remaining, .milliseconds(20))
            try await Task.sleep(for: chunk)
            remaining -= chunk
        }
        if request.isCancelled() { throw ImportError.cancelled }
        if let importError { throw importError }
        return ImportSummary(processed: 2, inserted: 2, failed: 0)
    }
}

final class ExplainingStubAdapter: StubAdapter, SupportsExplain, @unchecked Sendable {
    var explainDelay: Duration = .zero
    var explainError: (any Error)?
    private var explained: [DatabaseCommand] = []

    var explainedCommands: [DatabaseCommand] { lock.withLock { explained } }

    func explain(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        lock.withLock { explained.append(command) }
        if explainDelay > .zero { try await Task.sleep(for: explainDelay) }
        try Task.checkCancellation()
        if let explainError { throw explainError }
        return .documents(
            [.object([("stage", .string("STUB_PLAN"))])],
            meta: ResultMeta(count: 1, truncated: false, elapsedMilliseconds: 1))
    }
}

final class StatisticsStubAdapter: StubAdapter, SupportsTableStatistics, @unchecked Sendable {
    var statisticsResult = TableStatistics(estimatedRows: 42, totalBytes: 4_096, indexBytes: 1_024)
    var statisticsError: (any Error)?
    private var requested: [DatabaseObject] = []

    var statisticsRequests: [DatabaseObject] { lock.withLock { requested } }

    func tableStatistics(for object: DatabaseObject) async throws -> TableStatistics {
        lock.withLock { requested.append(object) }
        if let statisticsError { throw statisticsError }
        return statisticsResult
    }
}

/// Server-activity stub (ROADMAP M2 ⑨): fixture rows, injected errors, and a
/// kill log; a successful kill removes the row so the store's refresh is
/// observable.
final class ActivityStubAdapter: StubAdapter, SupportsServerActivity, @unchecked Sendable {
    var activities: [ServerActivity] = [
        ServerActivity(id: "101", user: "etl", database: "shop",
                       statement: "UPDATE products SET price = price * 1.05",
                       age: .seconds(12), state: "Query"),
        ServerActivity(id: "102", user: "app", database: "shop",
                       statement: nil, age: nil, state: "Sleep"),
    ]
    var activityError: (any Error)?
    var killError: (any Error)?
    private var kills: [String] = []

    var killRequests: [String] { lock.withLock { kills } }

    func listActivity() async throws -> [ServerActivity] {
        if let activityError { throw activityError }
        return lock.withLock { activities }
    }

    func killActivity(id: String) async throws {
        lock.withLock { kills.append(id) }
        if let killError { throw killError }
        lock.withLock { activities.removeAll { $0.id == id } }
    }
}

/// Schema-introspection stub ("View Schema"): canned per-table schemas and
/// relationship edges, injected errors, and a call log.
final class SchemaStubAdapter: StubAdapter, SupportsSchemaIntrospection, @unchecked Sendable {
    var schemaResults: [TableSchema] = []
    var relationResult: [TableRelation] = []
    var schemaError: (any Error)?
    var relationsError: (any Error)?
    private var schemaRequests: [DatabaseObject] = []
    private var relationRequests = 0

    var requestedSchemas: [DatabaseObject] { lock.withLock { schemaRequests } }
    var relationRequestCount: Int { lock.withLock { relationRequests } }

    func schema(for object: DatabaseObject) async throws -> TableSchema {
        lock.withLock { schemaRequests.append(object) }
        if let schemaError { throw schemaError }
        guard let result = lock.withLock({ schemaResults.first { $0.object == object } }) else {
            throw AdapterError.notFound("No stub schema for \(object.name).")
        }
        return result
    }

    func allForeignKeys() async throws -> [TableRelation] {
        lock.withLock { relationRequests += 1 }
        if let relationsError { throw relationsError }
        return lock.withLock { relationResult }
    }
}

/// Isolated UserDefaults suite per call: tests removing demo connections
/// write the removed-demo preference, which must never reach real defaults.
func makeIsolatedDefaults() -> UserDefaults {
    let suite = "dbbbb-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
func makeStore() -> SessionStore {
    SessionStore(connectionStore: nil, queryLibrary: nil, defaults: makeIsolatedDefaults())
}

@MainActor
@discardableResult
func addStubSession(to store: SessionStore, adapter: StubAdapter) async throws -> UUID {
    store.makeAdapter = { _ in adapter }
    try await store.addConnection(.sqlite(.init(name: adapter.profile.name, filePath: "stub.db")))
    return adapter.profile.id
}

@MainActor
func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
