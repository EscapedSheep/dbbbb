import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
struct SessionStoreConnectionTests {
    @Test func removingLastConnectionResetsLoadingState() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.listObjectsDelay = .milliseconds(800)
        try await addStubSession(to: store, adapter: adapter)
        #expect(store.isLoadingObjects)

        for id in store.sessions.filter({ $0.profile.demo }).map(\.id) {
            store.removeConnection(id)
        }
        store.removeConnection(adapter.profile.id)

        #expect(store.sessions.isEmpty)
        #expect(store.selectedConnectionID == nil)
        #expect(!store.isLoadingObjects)
        #expect(store.objects.isEmpty)

        // The stale load completing later must not resurrect anything.
        try? await Task.sleep(for: .milliseconds(1000))
        #expect(!store.isLoadingObjects)
        #expect(store.objects.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func removingSelectedConnectionCancelsInFlightQuery() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.executeDelay = .seconds(30)
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select 1"
        store.runQuery()
        #expect(store.isExecuting)

        store.removeConnection(adapter.profile.id)
        #expect(!store.isExecuting)
        #expect(store.result == nil)
        #expect(store.errorMessage == nil)
        #expect(await waitUntil { adapter.cancelledRequestIDs.count == 1 })
        // Selection moved to a surviving demo connection.
        #expect(store.selectedConnectionID != nil)
    }

    @Test func restoreSkipsConnectionsRemovedDuringReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionStore = ConnectionStore(directory: directory, keychain: InMemoryKeychainStore())
        let zombieID = UUID()
        try connectionStore.save(
            PersistedConnection(id: zombieID, input: .sqlite(.init(name: "Zombie", filePath: "zombie.db"))),
            secret: nil)

        let adapter = StubAdapter(name: "Zombie")
        let store = SessionStore(connectionStore: connectionStore, queryLibrary: nil, defaults: makeIsolatedDefaults())
        store.makeAdapter = { _ in
            // The user deletes the connection while the restore is reconnecting.
            try? connectionStore.remove(id: zombieID)
            return adapter
        }

        #expect(await waitUntil { adapter.wasClosed })
        #expect(!store.sessions.contains { $0.id == zombieID })
        #expect(store.errorMessage == nil)
    }

    @Test func restoreKeepsConnectionsStillInManifest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionStore = ConnectionStore(directory: directory, keychain: InMemoryKeychainStore())
        let keptID = UUID()
        try connectionStore.save(
            PersistedConnection(id: keptID, input: .sqlite(.init(name: "Kept", filePath: "kept.db"))),
            secret: nil)

        let adapter = StubAdapter(name: "Kept")
        let store = SessionStore(connectionStore: connectionStore, queryLibrary: nil, defaults: makeIsolatedDefaults())
        store.makeAdapter = { _ in adapter }

        #expect(await waitUntil { store.sessions.contains { $0.id == keptID } })
        #expect(store.errorMessage == nil)
    }

    /// Regression: an unreachable server must surface a real error fast — the
    /// Add sheet used to spin forever because adapter internals can sit on
    /// futures that ignore task cancellation.
    @Test func addConnectionTimesOutAndCanBeRetried() async throws {
        let store = makeStore()
        store.connectProbeTimeout = .milliseconds(100)

        let hanging = StubAdapter(name: "Hanging")
        hanging.listObjectsDelay = .seconds(3600)
        store.makeAdapter = { _ in hanging }

        do {
            try await store.addConnection(.sqlite(.init(name: "Hanging", filePath: "hanging.db")))
            Issue.record("an unreachable server must fail instead of spinning forever")
        } catch let error as SessionStore.ConnectProbeTimeoutError {
            #expect(error.userMessage.contains("did not respond in time"))
        }
        #expect(!store.sessions.contains { $0.profile.name == "Hanging" })

        // The sheet stays usable: a corrected attempt succeeds right away.
        let healthy = StubAdapter(name: "Healthy")
        store.makeAdapter = { _ in healthy }
        try await store.addConnection(.sqlite(.init(name: "Healthy", filePath: "healthy.db")))
        #expect(store.sessions.contains { $0.profile.name == "Healthy" })
    }

    @Test func editingObjectFailsClosedForDemoProfiles() async throws {
        let store = makeStore()
        let demoAdapter = EditingStubAdapter(demo: true)
        try await addStubSession(to: store, adapter: demoAdapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.previewedObject == StubAdapter.table })
        // A demo profile never offers editing, even with a capable adapter.
        #expect(store.editingObject == nil)

        let realAdapter = EditingStubAdapter()
        try await addStubSession(to: store, adapter: realAdapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.previewedObject == StubAdapter.table })
        #expect(store.editingObject == StubAdapter.table)
    }
}
