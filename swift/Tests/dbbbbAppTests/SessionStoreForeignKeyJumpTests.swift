import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Foreign-key jump state machine (ROADMAP M1 ⑤): the row context menu is
/// gated on a preview of an object whose adapter conforms, NULL/missing FK
/// legs hide the entry, and the jump opens the referenced object with
/// equality filters on the referenced columns from page one.
@MainActor
struct SessionStoreForeignKeyJumpTests {
    private let users = DatabaseObject(id: "u1", parentID: nil, name: "users", kind: .table)
    private let orders = DatabaseObject(id: "o1", parentID: nil, name: "orders", kind: .table)

    private var userFK: ForeignKey {
        ForeignKey(columns: ["user_id"], referencedObject: users, referencedColumns: ["id"])
    }

    private var orderFK: ForeignKey {
        ForeignKey(
            columns: ["order_org", "order_no"],
            referencedObject: orders,
            referencedColumns: ["org_id", "order_no"])
    }

    private func makeJumpStore(
        adapter: StubAdapter,
        objects: [DatabaseObject]? = nil
    ) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = objects ?? [users, orders]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        return store
    }

    private func previewAndSettle(
        _ store: SessionStore, _ object: DatabaseObject, adapter: StubAdapter
    ) async {
        store.preview(object)
        #expect(await waitUntil { store.result != nil })
    }

    // MARK: Metadata loading and menu gating

    @Test func metadataLoadsAfterPreviewAndOffersJump() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        #expect(adapter.foreignKeyRequests == [orders])

        let jumps = store.foreignKeyJumps(forRow: [("id", .number(10)), ("user_id", .number(2))])
        #expect(jumps == [userFK])
    }

    /// A non-conforming adapter (and MongoDB) fails closed: no menu entries.
    @Test func nonConformingAdapterOffersNoJumps() async throws {
        let adapter = StubAdapter()
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.previewedForeignKeys.isEmpty)
        #expect(store.foreignKeyJumps(forRow: [("user_id", .number(2))]).isEmpty)
    }

    /// Ad-hoc query results have no previewed object, so no jumps — even when
    /// the previous screen had FK metadata loaded.
    @Test func adHocResultOffersNoJumps() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })

        store.queryText = "select * from orders;"
        store.runQuery()
        #expect(await waitUntil { !store.isExecuting })
        #expect(store.previewedObject == nil)
        #expect(store.previewedForeignKeys.isEmpty)
        #expect(store.foreignKeyJumps(forRow: [("user_id", .number(2))]).isEmpty)
    }

    /// A NULL FK leg can never match the referenced row — the entry hides.
    @Test func nullForeignKeyColumnHidesJump() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        #expect(store.foreignKeyJumps(forRow: [("id", .number(10)), ("user_id", .null)]).isEmpty)
    }

    /// A result that does not even contain the FK column (column-limited
    /// preview) hides the entry.
    @Test func missingForeignKeyColumnHidesJump() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        #expect(store.foreignKeyJumps(forRow: [("id", .number(10))]).isEmpty)
    }

    /// Multi-column FK: offered only when every leg is present and non-NULL.
    @Test func multiColumnForeignKeyRequiresAllLegs() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [orderFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, users, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [orderFK] })

        #expect(store.foreignKeyJumps(forRow: [
            ("order_org", .number(1)), ("order_no", .null)]).isEmpty)
        #expect(store.foreignKeyJumps(forRow: [
            ("order_org", .number(1))]).isEmpty)
        #expect(store.foreignKeyJumps(forRow: [
            ("order_org", .number(1)), ("order_no", .number(2))]) == [orderFK])
    }

    /// A key pointing at a non-previewable object kind is never offered.
    @Test func nonPreviewableTargetHidesJump() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [ForeignKey(
            columns: ["user_id"],
            referencedObject: DatabaseObject(id: "s1", parentID: nil, name: "main", kind: .schema),
            referencedColumns: ["id"])]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { !store.previewedForeignKeys.isEmpty })
        #expect(store.foreignKeyJumps(forRow: [("user_id", .number(2))]).isEmpty)
    }

    /// FK metadata failures degrade to no menu entries; the preview stays.
    @Test func metadataFailureKeepsPreviewAndHidesMenu() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeysError = AdapterError.sessionClosed
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.result != nil)
        #expect(store.errorMessage == nil)
        #expect(store.previewedForeignKeys.isEmpty)
    }

    // MARK: The jump

    /// The jump opens the referenced object at page one with equality filters
    /// on the referenced columns (values taken from the selected row), no
    /// sort or grid filter, and the shared page size.
    @Test func jumpConstructsEqualityFilteredPreview() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        #expect(adapter.previewRequests.count == 1)

        store.jumpToReferencedRow(userFK, row: [("id", .number(10)), ("user_id", .number(2))])
        #expect(await waitUntil { adapter.previewRequests.count == 2 })

        let request = try #require(adapter.previewRequests.last)
        #expect(request.object == users)
        #expect(request.offset == 0)
        #expect(request.limit == SessionStore.previewPageSize)
        #expect(request.sort == nil)
        #expect(request.filter == nil)
        #expect(request.equalities == [PreviewRequest.Equality(column: "id", value: .number(2))])
        #expect(store.previewedObject == users)
        #expect(store.previewOffset == 0)
        #expect(store.previewEqualities == request.equalities)
    }

    /// Multi-column jumps carry one equality per referenced column, in key
    /// order, with the row's values.
    @Test func multiColumnJumpCarriesEveryLeg() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [orderFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, users, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [orderFK] })

        store.jumpToReferencedRow(orderFK, row: [
            ("order_org", .number(7)), ("order_no", .number(3))])
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        #expect(adapter.previewRequests.last?.equalities == [
            PreviewRequest.Equality(column: "org_id", value: .number(7)),
            PreviewRequest.Equality(column: "order_no", value: .number(3)),
        ])
    }

    /// Page turns after a jump keep the equality filters (the user is
    /// browsing the referenced object filtered to the referenced row).
    @Test func pageTurnAfterJumpKeepsEqualities() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.previewTruncated = true
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        store.jumpToReferencedRow(userFK, row: [("user_id", .number(2))])
        #expect(await waitUntil { adapter.previewRequests.count == 2 })

        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })
        let request = try #require(adapter.previewRequests.last)
        #expect(request.offset == SessionStore.previewPageSize)
        #expect(request.equalities == [PreviewRequest.Equality(column: "id", value: .number(2))])
    }

    /// A failed jump target preview goes through the redacted banner and
    /// never leaves the preview pointer aimed at data that never arrived.
    @Test func failedJumpSurfacesBannerError() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })

        adapter.previewError = AdapterError.sessionClosed
        store.jumpToReferencedRow(userFK, row: [("user_id", .number(2))])
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.previewedObject == nil)
        #expect(store.previewEqualities.isEmpty)
        #expect(store.previewedForeignKeys.isEmpty)
    }

    /// A jump that does not match the loaded metadata (stale menu payload) is
    /// refused silently.
    @Test func staleJumpIsRefused() async throws {
        let adapter = ForeignKeysStubAdapter()
        adapter.foreignKeyResult = [userFK]
        let store = try await makeJumpStore(adapter: adapter)
        await previewAndSettle(store, orders, adapter: adapter)
        #expect(await waitUntil { store.previewedForeignKeys == [userFK] })
        #expect(adapter.previewRequests.count == 1)

        store.jumpToReferencedRow(orderFK, row: [
            ("order_org", .number(1)), ("order_no", .number(2))])
        try await Task.sleep(for: .milliseconds(50))
        #expect(adapter.previewRequests.count == 1)
        #expect(store.previewedObject == orders)
    }
}
