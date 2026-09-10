import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// BullMQ stub: document pages driven by the query's cursor, plus a canned
/// collectBullmqJobs for snapshot syncs. Five jobs total, two per page.
final class BullmqStubAdapter: StubAdapter, SupportsBullmqSnapshot, @unchecked Sendable {
    /// Total canned jobs; each page holds `pageSize`.
    var totalJobs = 5
    var pageSize = 2
    /// Delay applied only to continuation pages (cursor > 0).
    var continuationDelay: Duration = .zero
    var collectBatchSize = 2
    var collectBatchDelay: Duration = .zero
    private var cancelled: Set<UUID> = []
    private var executed: [DatabaseCommand] = []

    var cancelledIDs: [UUID] { lock.withLock { Array(cancelled) } }
    var executedJobTexts: [String] {
        lock.withLock { executed }.compactMap { command in
            guard case .bullmqJobs(let text) = command else { return nil }
            return text
        }
    }

    init() {
        super.init(engine: .bullmq, readOnly: true, name: "Stub")
        objects = [DatabaseObject(id: "emails", parentID: nil, name: "emails", kind: .collection)]
    }

    private static func document(_ id: Int) -> DisplayValue {
        .object([
            ("id", .string(String(id))),
            ("queue", .string("emails")),
            ("state", .string("failed")),
            ("name", .string("welcome-email")),
        ])
    }

    private static func cursor(of command: DatabaseCommand) -> Int {
        guard case .bullmqJobs(let text) = command,
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cursor = parsed["cursor"] as? Int else { return 0 }
        return cursor
    }

    override func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult {
        lock.withLock { executed.append(command) }
        let cursor = Self.cursor(of: command)
        if cursor > 0, continuationDelay > .zero {
            try await Task.sleep(for: continuationDelay)
            try Task.checkCancellation()
        }
        if lock.withLock({ cancelled.contains(options.requestID) }) {
            throw AdapterError.notFound("BullMQ query cancelled.")
        }
        let page = Array((cursor + 1)...min(cursor + pageSize, totalJobs))
        let documents = page.map(Self.document)
        let nextCursor = cursor + page.count
        return .documents(documents, meta: ResultMeta(
            count: documents.count,
            truncated: nextCursor < totalJobs,
            elapsedMilliseconds: 1,
            scanned: page.count,
            total: totalJobs,
            nextCursor: nextCursor))
    }

    override func cancel(requestID: UUID) async throws {
        lock.withLock { _ = cancelled.insert(requestID) }
    }

    func collectBullmqJobs(
        options: BullmqCollectOptions,
        onBatch: @Sendable ([DisplayValue]) async throws -> Void
    ) async throws -> Int {
        var position = 0
        var collected = 0
        while position < totalJobs {
            if let requestID = options.requestID, lock.withLock({ cancelled.contains(requestID) }) {
                throw AdapterError.notFound("BullMQ query cancelled.")
            }
            if collectBatchDelay > .zero {
                try await Task.sleep(for: collectBatchDelay)
                try Task.checkCancellation()
            }
            let batch = Array((position + 1)...min(position + collectBatchSize, totalJobs)).map(Self.document)
            position += batch.count
            collected += batch.count
            try await onBatch(batch)
        }
        return collected
    }
}

/// BullMQ app wiring: continue-scan accumulation, staleness/cancellation, and
/// the snapshot sync coordinator (registration, non-persistence, cleanup).
@MainActor
struct SessionStoreBullmqTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-bullmq-app-test-\(UUID().uuidString)")
    }

    @discardableResult
    private func addBullmqSession(
        to store: SessionStore, adapter: BullmqStubAdapter
    ) async throws -> UUID {
        store.makeAdapter = { _ in adapter }
        try await store.addConnection(.bullmq(.init(name: "Stub", host: "stub", prefix: "bull", readOnly: true)))
        #expect(await waitUntil { !store.isLoadingObjects })
        return adapter.profile.id
    }

    private func runDefaultQuery(on store: SessionStore) async {
        store.runQuery()
        #expect(await waitUntil { store.result != nil && !store.isExecuting })
    }

    // MARK: Continue scan

    @Test func continueScanAppendsPagesAndAccumulatesMeta() async throws {
        let store = makeStore()
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)

        let editorText = store.queryText
        await runDefaultQuery(on: store)
        guard case .documents(let firstDocs, let firstMeta) = store.result else {
            Issue.record("expected documents")
            return
        }
        #expect(firstDocs.count == 2)
        #expect(firstMeta.truncated)
        #expect(firstMeta.scanned == 2)
        #expect(firstMeta.total == 5)
        #expect(firstMeta.nextCursor == 2)
        #expect(store.canContinueScan)

        store.continueScan()
        #expect(await waitUntil { !store.isExecuting })
        guard case .documents(let secondDocs, let secondMeta) = store.result else {
            Issue.record("expected documents")
            return
        }
        // Appended page, accumulated meta, latest cursor.
        #expect(secondDocs.count == 4)
        #expect(secondMeta.count == 4)
        #expect(secondMeta.scanned == 4)
        #expect(secondMeta.truncated)
        #expect(secondMeta.nextCursor == 4)
        #expect(secondMeta.elapsedMilliseconds == 2)
        // The editor text is untouched: a fresh Run starts from the top.
        #expect(store.queryText == editorText)
        // The continuation ran with only the cursor replaced.
        let continuedText = try #require(adapter.executedJobTexts.last)
        #expect(continuedText.contains(#""cursor":2"#))
        #expect(continuedText.contains(#""queue":"emails""#))

        store.continueScan()
        #expect(await waitUntil { !store.isExecuting })
        guard case .documents(let finalDocs, let finalMeta) = store.result else {
            Issue.record("expected documents")
            return
        }
        #expect(finalDocs.count == 5)
        #expect(!finalMeta.truncated)
        #expect(!store.canContinueScan)
        #expect(store.errorMessage == nil)
    }

    @Test func continueScanRejectsInvalidEditorJSON() async throws {
        let store = makeStore()
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)
        await runDefaultQuery(on: store)
        #expect(store.canContinueScan)

        store.queryText = "{ nope"
        store.continueScan()
        #expect(store.errorMessage == "The BullMQ query is not valid JSON; fix it before continuing the scan.")
        guard case .documents(let docs, _) = store.result else {
            Issue.record("result must stay")
            return
        }
        #expect(docs.count == 2)
    }

    @Test func continueScanCompletionAfterConnectionSwitchIsDiscarded() async throws {
        let store = makeStore()
        let adapterA = BullmqStubAdapter()
        adapterA.continuationDelay = .milliseconds(200)
        let adapterB = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapterA)
        await runDefaultQuery(on: store)

        // Register a second session, then switch mid-continuation.
        store.makeAdapter = { _ in adapterB }
        try await store.addConnection(.bullmq(.init(name: "B", host: "stub", prefix: "bull", readOnly: true)))
        store.selectConnection(adapterA.profile.id)
        #expect(await waitUntil { !store.isLoadingObjects && !store.queryText.isEmpty })
        store.runQuery()
        #expect(await waitUntil { store.result != nil && !store.isExecuting })
        store.continueScan()
        #expect(store.isExecuting)
        store.selectConnection(adapterB.profile.id)

        // Let the stale continuation finish; it must be discarded.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(store.selectedConnectionID == adapterB.profile.id)
        #expect(store.errorMessage == nil)
        #expect(store.result == nil)
    }

    @Test func continueScanCanBeCancelled() async throws {
        let store = makeStore()
        let adapter = BullmqStubAdapter()
        adapter.continuationDelay = .milliseconds(300)
        try await addBullmqSession(to: store, adapter: adapter)
        await runDefaultQuery(on: store)

        store.continueScan()
        #expect(store.isExecuting)
        store.cancelQuery()
        #expect(await waitUntil { !store.isExecuting })
        guard case .documents(let docs, _)? = store.result else {
            Issue.record("the first page stays on screen")
            return
        }
        #expect(docs.count == 2)
        #expect(store.errorMessage == nil)
        #expect(!adapter.cancelledIDs.isEmpty)
    }

    // MARK: Snapshot sync

    private func makeSnapshotStack() -> (SessionStore, BullmqSnapshotStore, ConnectionStore, URL) {
        let directory = makeTempDirectory()
        let snapshotStore = BullmqSnapshotStore(
            directory: directory.appendingPathComponent("bullmq-snapshots"))
        let connectionStore = ConnectionStore(
            directory: directory.appendingPathComponent("connections"),
            keychain: InMemoryKeychainStore())
        let store = SessionStore(
            connectionStore: connectionStore, queryLibrary: nil, snapshotStore: snapshotStore)
        return (store, snapshotStore, connectionStore, directory)
    }

    @Test func syncCreatesReadOnlyUnpersistedSnapshotSession() async throws {
        let (store, snapshotStore, connectionStore, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)
        #expect(store.canSyncBullmqSnapshot)
        #expect(store.bullmqSyncQueues == ["emails"])

        let succeeded = await store.syncBullmqSnapshot(queue: "emails")
        #expect(succeeded)

        let snapshot = try #require(store.sessions.last)
        #expect(snapshot.profile.engine == .sqlite)
        #expect(snapshot.profile.readOnly)
        #expect(snapshot.profile.name == "Snapshot: emails (from Stub)")
        #expect(store.selectedConnectionID == snapshot.id)

        let file = snapshotStore.snapshotFileURL(connectionID: adapter.profile.id, queue: "emails")
        #expect(FileManager.default.fileExists(atPath: file.path))

        // The snapshot is queryable SQL: all five jobs landed.
        let result = try await snapshot.adapter.execute(
            .sql("select count(*) as c from jobs"), options: ExecuteOptions())
        guard case .rows(_, let rows, _) = result else {
            Issue.record("expected rows")
            return
        }
        #expect(rows.first?.first == .number(5))
        let byQueue = try await snapshot.adapter.execute(
            .sql("select count(*) as c from jobs where queue = 'emails'"),
            options: ExecuteOptions())
        guard case .rows(_, let queueRows, _) = byQueue else {
            Issue.record("expected rows")
            return
        }
        #expect(queueRows.first?.first == .number(5))

        // Not persisted: the manifest holds only the original connection.
        #expect(connectionStore.loadConnections().count == 1)
        #expect(connectionStore.loadConnections().first?.name == "Stub")
    }

    @Test func resyncReplacesTheSnapshotSessionAndFile() async throws {
        let (store, snapshotStore, _, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)

        #expect(await store.syncBullmqSnapshot(queue: "emails"))
        let firstID = try #require(store.sessions.last).id
        adapter.totalJobs = 3
        store.selectConnection(adapter.profile.id)
        #expect(await store.syncBullmqSnapshot(queue: "emails"))
        let second = try #require(store.sessions.last)

        // The old session is gone; exactly one snapshot session exists.
        #expect(!store.sessions.contains { $0.id == firstID })
        #expect(store.sessions.filter { $0.profile.name.hasPrefix("Snapshot:") }.count == 1)
        let result = try await second.adapter.execute(
            .sql("select count(*) as c from jobs"), options: ExecuteOptions())
        guard case .rows(_, let rows, _) = result else {
            Issue.record("expected rows")
            return
        }
        // Replacement, not accumulation.
        #expect(rows.first?.first == .number(3))
        _ = snapshotStore
    }

    @Test func removingSnapshotSessionDeletesItsFile() async throws {
        let (store, snapshotStore, _, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)
        #expect(await store.syncBullmqSnapshot(queue: "emails"))
        let snapshotID = try #require(store.sessions.last).id
        let file = snapshotStore.snapshotFileURL(connectionID: adapter.profile.id, queue: "emails")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.removeConnection(snapshotID)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!store.sessions.contains { $0.id == snapshotID })
    }

    @Test func exitCleanupDeletesAllSnapshotFiles() async throws {
        let (store, snapshotStore, _, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = BullmqStubAdapter()
        try await addBullmqSession(to: store, adapter: adapter)
        #expect(await store.syncBullmqSnapshot(queue: "emails"))
        let file = snapshotStore.snapshotFileURL(connectionID: adapter.profile.id, queue: "emails")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.deleteAllSnapshots()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func startupSweepsOrphansAndKeepsForeignFiles() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotStore = BullmqSnapshotStore(
            directory: directory.appendingPathComponent("bullmq-snapshots"))
        try snapshotStore.prepareDirectory()
        let orphan = snapshotStore.snapshotFileURL(connectionID: UUID(), queue: "emails")
        let foreign = snapshotStore.directory.appendingPathComponent("notes.sqlite")
        try Data("x".utf8).write(to: orphan)
        try Data("x".utf8).write(to: foreign)

        _ = SessionStore(connectionStore: nil, queryLibrary: nil, snapshotStore: snapshotStore)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func syncFailsClosedForNonBullmqSessions() async throws {
        let (store, _, _, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter()
        try await addStubSession(to: store, adapter: adapter)
        #expect(!store.canSyncBullmqSnapshot)
        let succeeded = await store.syncBullmqSnapshot(queue: "emails")
        #expect(!succeeded)
        #expect(store.errorMessage == "This connection does not support snapshots.")
    }

    @Test func cancellingSyncLeavesNoFileAndNoBanner() async throws {
        let (store, snapshotStore, _, directory) = makeSnapshotStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = BullmqStubAdapter()
        adapter.totalJobs = 100
        adapter.collectBatchDelay = .milliseconds(50)
        try await addBullmqSession(to: store, adapter: adapter)

        async let outcome = store.syncBullmqSnapshot(queue: "emails")
        try? await Task.sleep(for: .milliseconds(80))
        store.cancelBullmqSync()
        let succeeded = await outcome
        #expect(!succeeded)
        #expect(store.errorMessage == nil)
        #expect(!store.isBullmqSyncing)
        let temp = snapshotStore.temporaryFileURL(
            for: snapshotStore.snapshotFileURL(connectionID: adapter.profile.id, queue: "emails"))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(!FileManager.default.fileExists(
            atPath: snapshotStore.snapshotFileURL(connectionID: adapter.profile.id, queue: "emails").path))
    }

    // MARK: Demo

    @Test func demoBullmqSessionBrowsesAndSnapshots() async throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(
            connectionStore: nil, queryLibrary: nil,
            snapshotStore: BullmqSnapshotStore(
                directory: directory.appendingPathComponent("bullmq-snapshots")))
        let demo = try #require(store.sessions.first { $0.profile.engine == .bullmq })
        #expect(demo.profile.name == "Local Queues (BullMQ)")
        #expect(demo.adapter is any SupportsBullmqSnapshot)

        store.selectConnection(demo.id)
        #expect(await waitUntil { !store.isLoadingObjects })
        let queues = store.objects.filter { $0.kind == .collection }.map(\.name)
        #expect(queues == ["emails", "reports"])

        // The embedded adapter answers real job queries.
        store.queryText = #"{"queue":"emails","state":"failed"}"#
        await runDefaultQuery(on: store)
        guard case .documents(let docs, let meta)? = store.result else {
            Issue.record("expected documents")
            return
        }
        #expect(docs.count == 3)
        #expect(meta.total == 3)

        // Snapshots work against demo connections too.
        #expect(await store.syncBullmqSnapshot(queue: "emails"))
        let snapshot = try #require(store.sessions.last)
        let result = try await snapshot.adapter.execute(
            .sql("select state, count(*) as c from jobs group by state order by state"),
            options: ExecuteOptions())
        guard case .rows(_, let rows, _) = result else {
            Issue.record("expected rows")
            return
        }
        var counts: [String: Double] = [:]
        for row in rows {
            guard case .string(let state) = row[0], case .number(let count) = row[1] else { continue }
            counts[state] = count
        }
        #expect(counts == ["active": 1, "completed": 2, "delayed": 1, "failed": 3, "paused": 1, "waiting": 2])
    }
}
