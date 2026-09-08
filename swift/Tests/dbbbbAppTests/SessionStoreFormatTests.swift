import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Query formatting in the store (ROADMAP M3 查询格式化): the action formats
/// the active tab's editor text in place, and fails closed for MongoDB
/// (Extended JSON, not SQL) and empty text.
@MainActor
struct SessionStoreFormatTests {
    @Test func formatAppliesToActiveTabOnly() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select id from t where a = 1"
        store.newTab()
        let tabB = try #require(store.tabs.last)
        store.queryText = "select x from u"

        #expect(store.canFormatQuery)
        store.formatCurrentQuery()
        #expect(store.queryText == "select x\nfrom u")
        // The first tab's text is untouched.
        #expect(store.tabs[0].queryText == "select id from t where a = 1")
        store.selectTab(store.tabs[0].id)
        store.formatCurrentQuery()
        #expect(store.queryText == "select id\nfrom t\nwhere a = 1")
        _ = tabB
    }

    @Test func formatFailsClosedForMongoAndEmptyText() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(!store.canFormatQuery)  // MongoDB: Extended JSON, not SQL
        store.formatCurrentQuery()
        #expect(store.queryText == "{ }")

        let sqlStore = makeStore()
        let sqlAdapter = StubAdapter()
        sqlAdapter.objects = [StubAdapter.table]
        try await addStubSession(to: sqlStore, adapter: sqlAdapter)
        #expect(await waitUntil { !sqlStore.isLoadingObjects })
        sqlStore.queryText = "   "
        #expect(!sqlStore.canFormatQuery)
    }

    /// The in-place rewrite is still the verbatim query, token for token.
    @Test func formattingNeverAltersTokens() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        let original = "select 'tricky '' string', \"id\" from t -- note\nwhere x = $$v$$"
        store.queryText = original
        store.formatCurrentQuery()
        #expect(SQLFormatter.tokenize(store.queryText) == SQLFormatter.tokenize(original))
        #expect(store.errorMessage == nil)
    }
}
