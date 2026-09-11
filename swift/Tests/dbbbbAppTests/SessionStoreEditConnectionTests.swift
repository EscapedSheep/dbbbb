import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Connection editing: metadata-only edits update in place, parameter changes
/// probe-then-replace (fail closed on probe failure), blank passwords keep the
/// Keychain secret, demo/unsaved/removed connections are refused.
@MainActor
struct SessionStoreEditConnectionTests {
    private func makeStack() -> (SessionStore, ConnectionStore, InMemoryKeychainStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-edit-test-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let connectionStore = ConnectionStore(directory: directory, keychain: keychain)
        let store = SessionStore(connectionStore: connectionStore, queryLibrary: nil, defaults: makeIsolatedDefaults())
        return (store, connectionStore, keychain, directory)
    }

    private func postgresInput(name: String = "Editable", port: Int = 5432, password: String = "old-secret") -> ConnectionInput {
        .postgres(.init(
            name: name, host: "db.internal", port: port,
            username: "analyst", password: password, database: "warehouse",
            sslMode: .require, environment: .development, readOnly: false))
    }

    /// Adds a stub session through the real add path (probe + persist).
    /// Returns the session id; `factoryCount` counts adapter constructions.
    @discardableResult
    private func addEditableSession(
        to store: SessionStore,
        adapter: StubAdapter,
        input: ConnectionInput,
        factoryCount: Counter
    ) async throws -> UUID {
        store.makeAdapter = { _ in
            factoryCount.increment()
            return adapter
        }
        try await store.addConnection(input)
        return adapter.profile.id
    }

    private final class Counter: @unchecked Sendable {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test func metadataOnlyEditUpdatesInPlaceWithoutReconnect() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter(engine: .postgresql)
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapter, input: postgresInput(), factoryCount: counter)
        #expect(counter.value == 1)

        var edited = postgresInput(name: "Renamed")
        if case .postgres(var input) = edited {
            input.environment = .production
            input.password = "" // blank = keep
            edited = .postgres(input)
        }
        try await store.updateConnection(id: id, input: edited)

        // No new adapter was built; the live adapter instance is unchanged.
        #expect(counter.value == 1)
        let session = try #require(store.sessions.first { $0.id == id })
        #expect(session.profile.name == "Renamed")
        #expect(session.profile.environment == .production)
        // Connection params and the read-only flag are untouched.
        #expect(!session.profile.readOnly)
        #expect(session.profile.database == "stub")
        #expect(connectionStore.loadConnections().first?.name == "Renamed")
        #expect(connectionStore.loadConnections().first?.environment == .production)
        // Blank password kept the Keychain secret.
        #expect(try keychain.secret(for: id) == "old-secret")
    }

    @Test func parameterChangeProbesThenReplacesSession() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapterA = StubAdapter(engine: .postgresql, name: "A")
        let adapterB = StubAdapter(engine: .postgresql, name: "B")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapterA, input: postgresInput(), factoryCount: counter)

        store.makeAdapter = { _ in
            counter.increment()
            return adapterB
        }
        var edited = postgresInput(name: "Editable", port: 5433, password: "")
        if case .postgres(var input) = edited {
            input.password = "new-secret"
            edited = .postgres(input)
        }
        try await store.updateConnection(id: id, input: edited)

        // The session was replaced: same id, new adapter, old one closed.
        let session = try #require(store.sessions.first { $0.id == id })
        #expect(session.adapter as? StubAdapter === adapterB)
        #expect(await waitUntil { adapterA.wasClosed })
        // Manifest + Keychain follow the new parameters.
        #expect(connectionStore.loadConnections().first?.port == 5433)
        #expect(try keychain.secret(for: id) == "new-secret")
    }

    @Test func failedProbeKeepsTheWorkingSessionAndPersistence() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter(engine: .postgresql, name: "A")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapter, input: postgresInput(), factoryCount: counter)

        store.makeAdapter = { _ in
            counter.increment()
            throw AdapterError.notFound("probe failed")
        }
        var edited = postgresInput(port: 5999, password: "")
        if case .postgres(var input) = edited {
            input.password = "replacement-secret"
            edited = .postgres(input)
        }
        await #expect(throws: AdapterError.self) {
            try await store.updateConnection(id: id, input: edited)
        }

        // Old session intact, manifest and Keychain untouched.
        let session = try #require(store.sessions.first { $0.id == id })
        #expect(session.adapter as? StubAdapter === adapter)
        #expect(!adapter.wasClosed)
        #expect(connectionStore.loadConnections().first?.port == 5432)
        #expect(try keychain.secret(for: id) == "old-secret")
    }

    @Test func blankPasswordKeepsSecretWhenReconnecting() async throws {
        let (store, _, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapterA = StubAdapter(engine: .postgresql, name: "A")
        let adapterB = StubAdapter(engine: .postgresql, name: "B")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapterA, input: postgresInput(), factoryCount: counter)

        store.makeAdapter = { _ in
            counter.increment()
            return adapterB
        }
        // Port change with a blank password: reconnect keeps the old secret.
        try await store.updateConnection(id: id, input: postgresInput(port: 5434, password: ""))
        #expect(try keychain.secret(for: id) == "old-secret")
    }

    @Test func demoConnectionNeverOpensTheEditor() {
        let (store, _, _, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let demo = store.sessions.first { $0.profile.demo }
        #expect(demo != nil)
        store.beginEditConnection(demo!.id)
        #expect(store.editingConnection == nil)
    }

    @Test func editingARemovedConnectionFailsClosed() async throws {
        let (store, _, _, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter(engine: .postgresql)
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapter, input: postgresInput(), factoryCount: counter)

        store.removeConnection(id)
        await #expect(throws: AdapterError.self) {
            try await store.updateConnection(id: id, input: postgresInput(name: "Ghost"))
        }
    }

    @Test func editorPrefillsTheCurrentInput() async throws {
        let (store, _, _, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter(engine: .postgresql)
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapter, input: postgresInput(), factoryCount: counter)

        store.beginEditConnection(id)
        let editing = try #require(store.editingConnection)
        #expect(editing.id == id)
        guard case .postgres(let input) = editing.input else {
            Issue.record("expected postgres input")
            return
        }
        #expect(input.host == "db.internal")
        #expect(input.port == 5432)
        #expect(input.password == "old-secret")
        #expect(input.sslMode == .require)
    }

    @Test func unsavedSessionEditsFromTheInMemoryInput() async throws {
        let (store, connectionStore, _, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = StubAdapter(engine: .postgresql)
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapter, input: postgresInput(), factoryCount: counter)
        // Simulate a session whose manifest entry vanished (or was never saved).
        try connectionStore.remove(id: id)

        // The editor opens from the in-memory add-time input.
        store.beginEditConnection(id)
        let editing = try #require(store.editingConnection)
        #expect(!editing.isPersisted)
        guard case .postgres(let input) = editing.input else {
            Issue.record("expected postgres input")
            return
        }
        #expect(input.host == "db.internal")

        // Metadata-only edit: in place, no reconnect, nothing persisted.
        var edited = postgresInput(name: "Renamed Unsaved")
        if case .postgres(var pg) = edited {
            pg.environment = .staging
            pg.password = ""
            edited = .postgres(pg)
        }
        try await store.updateConnection(id: id, input: edited)
        #expect(counter.value == 1)
        #expect(store.sessions.first { $0.id == id }?.profile.name == "Renamed Unsaved")
        #expect(store.sessions.first { $0.id == id }?.profile.environment == .staging)
        #expect(connectionStore.loadConnections().isEmpty)
    }

    @Test func unsavedParameterChangeReconnectsWithoutPersisting() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapterA = StubAdapter(engine: .postgresql, name: "A")
        let adapterB = StubAdapter(engine: .postgresql, name: "B")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapterA, input: postgresInput(), factoryCount: counter)
        try connectionStore.remove(id: id)

        store.makeAdapter = { _ in
            counter.increment()
            return adapterB
        }
        // Blank password on an unsaved session keeps the add-time password
        // (the Keychain copy was deleted with the manifest entry).
        try await store.updateConnection(id: id, input: postgresInput(port: 5444, password: ""))
        #expect(store.sessions.first { $0.id == id }?.adapter as? StubAdapter === adapterB)
        // Still session-only: nothing lands in the manifest or Keychain.
        #expect(connectionStore.loadConnections().isEmpty)
        #expect(try keychain.secret(for: id) == nil)
    }

    @Test func unsavedEditWithRememberPersists() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapterA = StubAdapter(engine: .postgresql, name: "A")
        let adapterB = StubAdapter(engine: .postgresql, name: "B")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapterA, input: postgresInput(), factoryCount: counter)
        try connectionStore.remove(id: id)

        store.makeAdapter = { _ in
            counter.increment()
            return adapterB
        }
        var edited = postgresInput(name: "Saved Now", port: 5445, password: "")
        if case .postgres(var pg) = edited {
            pg.password = "fresh-secret"
            edited = .postgres(pg)
        }
        try await store.updateConnection(id: id, input: edited, remember: true)

        let record = try #require(connectionStore.loadConnections().first)
        #expect(record.name == "Saved Now")
        #expect(record.port == 5445)
        #expect(try keychain.secret(for: id) == "fresh-secret")
    }

    @Test func unsavedFailedProbeKeepsSessionAndNothingPersisted() async throws {
        let (store, connectionStore, keychain, directory) = makeStack()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapterA = StubAdapter(engine: .postgresql, name: "A")
        let counter = Counter()
        let id = try await addEditableSession(to: store, adapter: adapterA, input: postgresInput(), factoryCount: counter)
        try connectionStore.remove(id: id)

        store.makeAdapter = { _ in
            counter.increment()
            throw AdapterError.notFound("probe failed")
        }
        await #expect(throws: AdapterError.self) {
            try await store.updateConnection(id: id, input: postgresInput(port: 5999), remember: true)
        }
        #expect(store.sessions.first { $0.id == id }?.adapter as? StubAdapter === adapterA)
        #expect(connectionStore.loadConnections().isEmpty)
        #expect(try keychain.secret(for: id) == nil)
    }
}
