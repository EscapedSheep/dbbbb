import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Preview paging/sort/filter state machine (ROADMAP M1 ①②): page turns and
/// grid shaping go through the same requestID path as queries, switching
/// objects/connections or refreshing zeroes the state, and the edit-refresh
/// re-preview keeps the current page.
@MainActor
struct SessionStorePreviewPagingTests {
    private func makePreviewingStore(
        adapter: StubAdapter,
        objects: [DatabaseObject] = [StubAdapter.table, StubAdapter.otherTable]
    ) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = objects
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        return store
    }

    private func previewAndSettle(_ store: SessionStore, _ object: DatabaseObject, adapter: StubAdapter) async {
        store.preview(object)
        #expect(await waitUntil { store.result != nil })
        #expect(adapter.previewRequests.count == 1)
    }

    @Test func previewStartsAtPageOneUnshaped() async throws {
        let adapter = StubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil })

        let request = try #require(adapter.previewRequests.first)
        #expect(request.object == StubAdapter.table)
        #expect(request.offset == 0)
        #expect(request.limit == SessionStore.previewPageSize)
        #expect(request.sort == nil)
        #expect(request.filter == nil)
        #expect(store.previewOffset == 0)
        #expect(store.previewPageIndex == 0)
        #expect(!store.previewHasPreviousPage)
        #expect(!store.previewHasNextPage)
    }

    @Test func nextAndPreviousPageTurn() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        #expect(store.previewHasNextPage)
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        #expect(adapter.previewRequests.last?.offset == SessionStore.previewPageSize)
        #expect(store.previewOffset == SessionStore.previewPageSize)
        #expect(store.previewPageIndex == 1)
        #expect(store.previewHasPreviousPage)

        store.previousPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })
        #expect(adapter.previewRequests.last?.offset == 0)
        #expect(store.previewOffset == 0)
    }

    /// Without a truncated result there is no next page; the turn is refused.
    @Test func nextPageIsClampedAtLastPage() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = false
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        #expect(!store.previewHasNextPage)
        store.nextPreviewPage()
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.previewRequests.count == 1)
        #expect(store.previewOffset == 0)
    }

    /// A first-page turn is refused.
    @Test func previousPageIsClampedAtFirstPage() async throws {
        let adapter = StubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        store.previousPreviewPage()
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.previewRequests.count == 1)
    }

    /// Page turns reuse the query cancellation path: the adapter sees the
    /// request id it was called with.
    @Test func pageTurnCancelsThroughRequestID() async throws {
        let adapter = StubAdapter()
        adapter.previewDelay = .milliseconds(400)
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)

        store.preview(StubAdapter.table)
        #expect(await waitUntil { adapter.previewRequests.count == 1 })
        #expect(store.isExecuting)

        store.cancelQuery()
        #expect(await waitUntil { !store.isExecuting })
        let previewRequestID = try #require(adapter.previewRequests.first?.requestID)
        #expect(adapter.cancelledRequestIDs.contains(previewRequestID))
    }

    @Test func filterResetsOffsetAndIsRecorded() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 2 })

        let filter = PreviewRequest.Filter(column: "id", contains: "42")
        store.setPreviewFilter(filter)
        #expect(await waitUntil { adapter.previewRequests.count == 3 })
        let request = try #require(adapter.previewRequests.last)
        #expect(request.offset == 0)
        #expect(request.filter == filter)
        #expect(store.previewFilter == filter)
        #expect(store.previewOffset == 0)
    }

    /// Empty filter text clears the filter instead of matching everything.
    @Test func emptyFilterTextClears() async throws {
        let adapter = StubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        store.setPreviewFilter(PreviewRequest.Filter(column: "id", contains: "42"))
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        store.setPreviewFilter(PreviewRequest.Filter(column: "id", contains: ""))
        #expect(await waitUntil { adapter.previewRequests.count == 3 })
        #expect(adapter.previewRequests.last?.filter == nil)
        #expect(store.previewFilter == nil)
    }

    @Test func sortResetsOffsetAndIsRecorded() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 2 })

        let sort = PreviewRequest.Sort(column: "id", ascending: false)
        store.setPreviewSort(sort)
        #expect(await waitUntil { adapter.previewRequests.count == 3 })
        #expect(adapter.previewRequests.last?.sort == sort)
        #expect(adapter.previewRequests.last?.offset == 0)
        #expect(store.previewSort == sort)

        store.setPreviewSort(nil)
        #expect(await waitUntil { adapter.previewRequests.count == 4 })
        #expect(adapter.previewRequests.last?.sort == nil)
        #expect(store.previewSort == nil)
    }

    /// Switching objects zeroes the browsing state.
    @Test func switchingObjectsResetsState() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)
        store.setPreviewSort(PreviewRequest.Sort(column: "id", ascending: true))
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })

        store.preview(StubAdapter.otherTable)
        #expect(await waitUntil { adapter.previewRequests.count == 4 })
        let request = try #require(adapter.previewRequests.last)
        #expect(request.object == StubAdapter.otherTable)
        #expect(request.offset == 0)
        #expect(request.sort == nil)
        #expect(store.previewOffset == 0)
        #expect(store.previewSort == nil)
    }

    /// Switching connections zeroes the browsing state (and clears the result).
    @Test func switchingConnectionsResetsState() async throws {
        let first = StubAdapter(name: "First")
        let second = StubAdapter(name: "Second")
        second.previewTruncated = true
        let store = makeStore()
        first.objects = [StubAdapter.table]
        second.objects = [StubAdapter.otherTable]
        store.makeAdapter = { input in
            input.name == "First" ? first : second
        }
        try await store.addConnection(.sqlite(.init(name: "First", filePath: "a.db")))
        try await store.addConnection(.sqlite(.init(name: "Second", filePath: "b.db")))
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.otherTable)
        #expect(await waitUntil { store.result != nil })
        store.nextPreviewPage()
        #expect(await waitUntil { second.previewRequests.count == 2 })

        store.selectConnection(first.profile.id)
        #expect(store.previewOffset == 0)
        #expect(store.previewSort == nil)
        #expect(store.previewFilter == nil)
        #expect(store.previewedObject == nil)
        #expect(store.result == nil)
    }

    /// Refreshing the object list zeroes the browsing state and reloads the
    /// visible preview from page one.
    @Test func refreshResetsStateAndReloadsPreview() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)
        store.setPreviewFilter(PreviewRequest.Filter(column: "id", contains: "7"))
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })

        store.refreshObjects()
        #expect(await waitUntil { adapter.previewRequests.count == 4 })
        let request = try #require(adapter.previewRequests.last)
        #expect(request.offset == 0)
        #expect(request.filter == nil)
        #expect(store.previewOffset == 0)
        #expect(store.previewFilter == nil)
    }

    /// After an edit, the review refresh re-previews at the current page and
    /// with the current sort/filter — the reviewer sees the change in place.
    @Test func editRefreshKeepsCurrentPage() async throws {
        let adapter = EditingStubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)
        let filter = PreviewRequest.Filter(column: "id", contains: "4")
        store.setPreviewFilter(filter)
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })

        let change = DataChange(
            object: StubAdapter.table,
            original: ["id": .number(1)],
            operation: .update(changed: ["id": .number(2)]))
        #expect(await store.applyDataChange(change))

        let request = try #require(adapter.previewRequests.last)
        #expect(request.offset == SessionStore.previewPageSize)
        #expect(request.filter == filter)
        #expect(store.previewOffset == SessionStore.previewPageSize)
    }

    /// A failed page load must not leave the preview pointer aimed at data
    /// that never arrived; the offset resets with the pointer.
    @Test func failedPageLoadResetsPreviewState() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        adapter.previewError = AdapterError.sessionClosed
        store.nextPreviewPage()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.previewedObject == nil)
        #expect(store.previewOffset == 0)
        #expect(store.result == nil)
    }

    /// While a page is loading, further page turns and shape changes are refused.
    @Test func actionsWhileExecutingAreIgnored() async throws {
        let adapter = StubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table, adapter: adapter)

        adapter.previewDelay = .milliseconds(300)
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        #expect(store.isExecuting)

        store.nextPreviewPage()
        store.previousPreviewPage()
        store.setPreviewFilter(PreviewRequest.Filter(column: "id", contains: "1"))
        store.setPreviewSort(PreviewRequest.Sort(column: "id", ascending: true))
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.previewRequests.count == 2)
        #expect(store.previewOffset == SessionStore.previewPageSize)
        #expect(store.previewFilter == nil)
        #expect(store.previewSort == nil)
    }
}
