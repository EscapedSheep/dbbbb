import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// SessionStore gating and command construction for the EXPLAIN viewer
/// (ROADMAP M2 ⑧): SQL engines run the prefixed statement through the normal
/// execute path; MongoDB goes through the adapter's explain capability and
/// respects the find/aggregate mode; every failure lands in the banner.
@MainActor
struct SessionStoreExplainTests {
    @Test func gatingRequiresQueryText() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "   "
        #expect(!store.canExplainQuery)
        store.explainCurrentQuery()
        #expect(adapter.executedCommands.isEmpty)

        store.queryText = "select 1"
        #expect(store.canExplainQuery)
    }

    @Test func sqliteExplainsWithQueryPlanPrefix() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .sqlite)
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select * from items"
        store.explainCurrentQuery()
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.executedCommands == [.sql("EXPLAIN QUERY PLAN select * from items")])
        #expect(store.errorMessage == nil)
        // Explains are meta-queries: nothing enters the query history path.
        #expect(store.previewedObject == nil)
    }

    @Test func postgresExplainsWithPlainPrefix() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .postgresql)
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "  select 1  "
        store.explainCurrentQuery()
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.executedCommands == [.sql("EXPLAIN select 1")])
    }

    @Test func explainFailureGoesToBanner() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.executeError = AdapterError.sessionClosed
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select 1"
        store.explainCurrentQuery()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.result == nil)
    }

    // MARK: MongoDB

    @Test func mongoExplainRequiresACollection() async throws {
        let store = makeStore()
        let adapter = ExplainingStubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "{ }"
        #expect(!store.canExplainQuery)
        store.explainCurrentQuery()
        #expect(store.errorMessage != nil)
        #expect(adapter.explainedCommands.isEmpty)
    }

    @Test func mongoExplainRespectsFindMode() async throws {
        let store = makeStore()
        let adapter = ExplainingStubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.insertQueryTemplate(for: StubAdapter.collection)
        store.queryText = "{ \"kind\": \"click\" }"
        #expect(store.canExplainQuery)
        store.explainCurrentQuery()
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.explainedCommands == [
            .mongoFind(collection: "events", filter: "{ \"kind\": \"click\" }"),
        ])
        // The explained command never reaches the normal execute path.
        #expect(adapter.executedCommands.isEmpty)
        #expect(store.resultIsDocuments)
    }

    @Test func mongoExplainRespectsAggregateMode() async throws {
        let store = makeStore()
        let adapter = ExplainingStubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.insertQueryTemplate(for: StubAdapter.collection)
        store.setMongoQueryMode(.aggregate)
        store.queryText = "[ { \"$match\": {} } ]"
        store.explainCurrentQuery()
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.explainedCommands == [
            .mongoAggregate(collection: "events", pipeline: "[ { \"$match\": {} } ]"),
        ])
    }

    /// Fail closed: a MongoDB adapter without the explain capability gets a
    /// banner, not a run.
    @Test func mongoExplainFailsClosedWithoutCapability() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.insertQueryTemplate(for: StubAdapter.collection)
        #expect(store.canExplainQuery)
        store.explainCurrentQuery()
        #expect(store.errorMessage == "This connection does not support explaining queries.")
        #expect(adapter.executedCommands.isEmpty)
        #expect(store.result == nil)
    }

    @Test func mongoExplainFailureGoesToBanner() async throws {
        let store = makeStore()
        let adapter = ExplainingStubAdapter(engine: .mongodb)
        adapter.explainError = AdapterError.notFound("The plan is gone.")
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.insertQueryTemplate(for: StubAdapter.collection)
        store.explainCurrentQuery()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.errorMessage == "The plan is gone.")
        #expect(store.result == nil)
    }
}
