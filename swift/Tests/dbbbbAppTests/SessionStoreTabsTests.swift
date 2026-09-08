import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Multi-result tabs (ROADMAP M3 多结果标签页): new/close/select, per-tab
/// state isolation, per-tab cancellation, background completions landing on
/// their own tab, connection-switch cleanup, and batch staging following its
/// tab.
@MainActor
struct SessionStoreTabsTests {
    @discardableResult
    private func makeStoreWithStub(
        adapter: StubAdapter,
        objects: [DatabaseObject] = [StubAdapter.table]
    ) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = objects
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        return store
    }

    // MARK: Tab lifecycle

    @Test func newTabIsSeededSelectedAndIsolated() async throws {
        let store = try await makeStoreWithStub(adapter: StubAdapter())
        let first = store.tabs[0]
        // The initial tab was seeded by loadObjects.
        #expect(store.queryText.contains("items"))
        store.queryText = "select 1;"

        store.newTab()
        #expect(store.tabs.count == 2)
        #expect(store.selectedTabID == store.tabs[1].id)
        // The new tab is seeded with the default query; editing it does not
        // touch the first tab.
        #expect(store.queryText.contains("items"))
        store.queryText = "select 2;"

        store.selectTab(first.id)
        #expect(store.selectedTabID == first.id)
        #expect(store.queryText == "select 1;")
        #expect(store.tabs[1].queryText == "select 2;")
    }

    @Test func closeTabSelectsNeighborAndLastCloseLeavesDraft() async throws {
        let store = try await makeStoreWithStub(adapter: StubAdapter())
        store.newTab()
        store.newTab()
        #expect(store.tabs.count == 3)
        let middle = store.tabs[1]

        store.selectTab(middle.id)
        store.closeTab(middle.id)
        #expect(store.tabs.count == 2)
        // The neighbor at the closed index takes over.
        #expect(store.selectedTabID == store.tabs[1].id)

        store.closeTab(store.tabs[0].id)
        store.closeTab(store.tabs[0].id)
        #expect(store.tabs.count == 1)
        #expect(store.tabs[0].isDraft || !store.tabs[0].queryText.isEmpty)
        #expect(store.selectedTabID == store.tabs[0].id)
    }

    // MARK: State isolation

    @Test func resultsStayOnTheirOwnTab() async throws {
        let adapter = StubAdapter()
        adapter.executeDelay = .milliseconds(150)
        let store = try await makeStoreWithStub(adapter: adapter)

        let tabA = store.tabs[0]
        store.queryText = "select 1;"
        store.runQuery()
        #expect(store.isExecuting)

        // Switching tabs mid-flight: the workspace shows the other tab's
        // (empty) state, and A's completion must not leak into it.
        store.newTab()
        let tabB = try #require(store.tabs.last)
        #expect(store.selectedTabID == tabB.id)
        #expect(!store.isExecuting)
        #expect(store.result == nil)

        #expect(await waitUntil { tabA.result != nil })
        #expect(store.result == nil)
        store.selectTab(tabA.id)
        #expect(store.result != nil)
        #expect(tabB.result == nil)
    }

    /// Cancellation is per tab: switching away does not cancel, and Cancel
    /// acts on the visible tab only.
    @Test func cancellationIsPerTab() async throws {
        let adapter = StubAdapter()
        adapter.executeDelay = .seconds(30)
        let store = try await makeStoreWithStub(adapter: adapter)

        let tabA = store.tabs[0]
        store.queryText = "select slow;"
        store.runQuery()
        #expect(tabA.isExecuting)

        store.newTab()
        #expect(!store.isExecuting)
        // The background tab still runs; nothing was cancelled.
        #expect(tabA.isExecuting)
        #expect(adapter.cancelledRequestIDs.isEmpty)

        store.selectTab(tabA.id)
        store.cancelQuery()
        #expect(await waitUntil { !tabA.isExecuting })
        #expect(adapter.cancelledRequestIDs.count == 1)
    }

    // MARK: Connection switch cleanup

    /// Switching connections cancels every tab's in-flight query and resets
    /// the workspace to one draft tab.
    @Test func connectionSwitchCancelsAllTabsAndResets() async throws {
        let adapter = StubAdapter()
        adapter.executeDelay = .seconds(30)
        let store = try await makeStoreWithStub(adapter: adapter)

        store.queryText = "select slow;"
        store.runQuery()
        store.newTab()
        #expect(store.tabs.count == 2)

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(await waitUntil { adapter.cancelledRequestIDs.count == 1 })
        #expect(store.tabs.count == 1)
        #expect(store.result == nil)
    }

    // MARK: Batch staging follows its tab

    @Test func pendingChangesFollowTheirTab() async throws {
        let adapter = EditingStubAdapter()
        let store = try await makeStoreWithStub(adapter: adapter)
        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil && !store.isExecuting })

        let tabA = store.tabs[0]
        let review = RecordReview(
            draft: RecordDraft(
                object: StubAdapter.table, environment: .development,
                columns: [ColumnMeta(name: "id", typeName: "int", numeric: true)],
                original: [("id", .number(1))]),
            changes: [("id", .number(1), .number(2))],
            changed: ["id": .number(2)],
            isDelete: false)
        store.stage(review)
        #expect(store.pendingChanges.count == 1)

        // The batch stays bound to tab A's previewed object: the new tab
        // shows an empty batch, switching back restores it.
        store.newTab()
        #expect(store.pendingChanges.isEmpty)
        #expect(!store.canStageChanges)
        store.selectTab(tabA.id)
        #expect(store.pendingChanges.count == 1)
        #expect(store.canStageChanges)
    }

    // MARK: Tab labels

    @Test func tabTitleAndDraftFlag() async throws {
        let draft = QueryTab()
        #expect(draft.isDraft)
        #expect(draft.title == "New Tab")

        let withQuery = QueryTab(queryText: "select * from orders\nwhere id = 1")
        #expect(withQuery.title == "select * from orders")
        #expect(withQuery.isDraft)

        let previewed = QueryTab()
        previewed.previewedObject = StubAdapter.table
        previewed.result = StubAdapter.rowsResult
        #expect(previewed.title == "items")
        #expect(!previewed.isDraft)
    }
}
