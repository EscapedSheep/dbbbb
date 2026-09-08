import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
struct SessionStoreIntrospectionTests {
    /// The menu capability is fail-closed: adapters that do not conform to
    /// `SupportsIntrospection` never offer it.
    @Test func capabilityHiddenForNonConformingAdapter() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(!store.canShowCreateStatement(for: StubAdapter.table))
        store.showCreateStatement(for: StubAdapter.table)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.createStatement == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func capabilityRequiresTableOrView() async throws {
        let store = makeStore()
        let adapter = IntrospectingStubAdapter()
        adapter.objects = [StubAdapter.schema, StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(store.canShowCreateStatement(for: StubAdapter.table))
        #expect(!store.canShowCreateStatement(for: StubAdapter.schema))
        #expect(!store.canShowCreateStatement(for: StubAdapter.collection))
    }

    @Test func showCreateStatementPresentsDDL() async throws {
        let store = makeStore()
        let adapter = IntrospectingStubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showCreateStatement(for: StubAdapter.table)
        #expect(await waitUntil { store.createStatement != nil })
        #expect(store.createStatement?.objectName == "items")
        #expect(store.createStatement?.ddl == "CREATE TABLE items (id INTEGER PRIMARY KEY);")
        #expect(adapter.introspectedObjects == [StubAdapter.table])
        #expect(store.errorMessage == nil)

        store.dismissCreateStatement()
        #expect(store.createStatement == nil)
    }

    /// Fetch failures go through the redacted banner, never into the sheet.
    @Test func showCreateStatementErrorGoesToBanner() async throws {
        let store = makeStore()
        let adapter = IntrospectingStubAdapter()
        adapter.introspectionError = AdapterError.notFound("This object is gone.")
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showCreateStatement(for: StubAdapter.table)
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.errorMessage == "This object is gone.")
        #expect(store.createStatement == nil)
    }

    /// Switching connections clears a presented sheet.
    @Test func presentationClearedOnConnectionSwitch() async throws {
        let store = makeStore()
        let adapter = IntrospectingStubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showCreateStatement(for: StubAdapter.table)
        #expect(await waitUntil { store.createStatement != nil })

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(store.createStatement == nil)
    }
}
