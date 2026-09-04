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

    var cancelledRequestIDs: [UUID] { lock.withLock { cancelled } }
    var wasClosed: Bool { lock.withLock { closed } }

    init(engine: DatabaseEngine = .sqlite, readOnly: Bool = false, demo: Bool = false, name: String = "Stub") {
        profile = ConnectionProfile(
            name: name, engine: engine, endpoint: "stub", database: "stub",
            environment: .development, readOnly: readOnly, demo: demo)
    }

    func listObjects() async throws -> [DatabaseObject] {
        if listObjectsDelay > .zero { try await Task.sleep(for: listObjectsDelay) }
        return objects
    }

    func previewObject(_ object: DatabaseObject) async throws -> QueryResult {
        if previewDelay > .zero { try await Task.sleep(for: previewDelay) }
        try Task.checkCancellation()
        if let previewError { throw previewError }
        return Self.rowsResult
    }

    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
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
        .rows(columns: [ColumnMeta(name: "id", typeName: "int", numeric: true)],
              rows: [[.number(1)]],
              meta: ResultMeta(count: 1, truncated: false, elapsedMilliseconds: 1))
    }

    static let table = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
    static let otherTable = DatabaseObject(id: "t2", parentID: nil, name: "orders", kind: .table)
}

final class EditingStubAdapter: StubAdapter, SupportsEditing, @unchecked Sendable {
    var applyDelay: Duration = .zero
    var applyError: (any Error)?

    func applyDataChange(_ change: DataChange) async throws -> QueryResult {
        if applyDelay > .zero { try await Task.sleep(for: applyDelay) }
        try Task.checkCancellation()
        if let applyError { throw applyError }
        return Self.rowsResult
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

@MainActor
func makeStore() -> SessionStore {
    SessionStore(connectionStore: nil, queryLibrary: nil)
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
