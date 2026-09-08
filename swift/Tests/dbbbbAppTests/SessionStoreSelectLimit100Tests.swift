import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
struct SessionStoreSelectLimit100Tests {
    /// Double-click on a SQL leaf: the editor gets the quoted select-limit-100
    /// AND the query executes immediately.
    @Test func doubleClickRunsQuotedSelectAndExecutes() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.runSelectLimit100(for: StubAdapter.table)
        #expect(store.queryText == #"select * from "items" limit 100;"#)
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.executedCommands == [.sql(#"select * from "items" limit 100;"#)])
        // A run, not a preview: no editing target is pinned.
        #expect(store.previewedObject == nil)
        #expect(store.errorMessage == nil)
    }

    /// Double-click on a MongoDB collection: the editor switches to find mode
    /// and the find runs against the collection.
    @Test func doubleClickMongoCollectionRunsFind() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.mongoQueryMode = .aggregate
        store.runSelectLimit100(for: StubAdapter.collection)
        #expect(store.mongoQueryMode == .find)
        #expect(store.queryText == "{ }")
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.executedCommands == [.mongoFind(collection: "events", filter: "{ }")])
        #expect(store.errorMessage == nil)
    }

    /// Non-leaf objects (schemas/databases) never produce a query.
    @Test func doubleClickOnSchemaDoesNothing() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.schema]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select 1;"
        store.runSelectLimit100(for: StubAdapter.schema)
        #expect(store.queryText == "select 1;")
        #expect(adapter.executedCommands.isEmpty)
    }

    /// While a query is in flight, double-click is ignored.
    @Test func doubleClickWhileExecutingIsIgnored() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table, StubAdapter.otherTable]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        adapter.executeDelay = .milliseconds(400)
        store.queryText = "select 1;"
        store.runQuery()
        #expect(store.isExecuting)
        #expect(await waitUntil { adapter.executedCommands.count == 1 })

        store.runSelectLimit100(for: StubAdapter.table)
        #expect(store.queryText == "select 1;")
        #expect(adapter.executedCommands == [.sql("select 1;")])
    }
}
