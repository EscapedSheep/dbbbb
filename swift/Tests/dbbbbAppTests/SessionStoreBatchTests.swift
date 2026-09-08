import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Batch staging in the store (ROADMAP M3 批量编辑暂存): stage/remove/clear,
/// the fail-closed gates, the sequential stop-at-first-failure apply, and the
/// discard semantics on connection/object switches.
@MainActor
struct SessionStoreBatchTests {
    private func makeReview(
        object: DatabaseObject = StubAdapter.table,
        id: Int = 1,
        environment: ConnectionEnvironment = .development
    ) -> RecordReview {
        let draft = RecordDraft(
            object: object, environment: environment,
            columns: [ColumnMeta(name: "id", typeName: "int", numeric: true),
                      ColumnMeta(name: "name", typeName: "text")],
            original: [("id", .number(Double(id))), ("name", .string("old\(id)"))])
        return RecordReview(
            draft: draft,
            changes: [("name", .string("old\(id)"), .string("new\(id)"))],
            changed: ["name": .string("new\(id)")],
            isDelete: false)
    }

    /// A store with an editable preview loaded.
    private func makeEditableStore(
        adapter: EditingStubAdapter,
        objects: [DatabaseObject] = [StubAdapter.table]
    ) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = objects
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        store.preview(StubAdapter.table)
        // Wait for the preview to fully settle (FK metadata fetch included)
        // so follow-up previews are not refused by the isExecuting guard.
        #expect(await waitUntil { store.result != nil && !store.isExecuting })
        return store
    }

    // MARK: Staging gates

    @Test func stageAppendsWhenEditable() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        #expect(store.canStageChanges)
        store.stage(makeReview())
        store.stage(makeReview(id: 2))
        #expect(store.pendingChanges.count == 2)
        #expect(store.pendingChanges[0].summaryText.contains("items"))
    }

    @Test func stageFailsClosedForNonEditingAdapter() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil })

        #expect(!store.canStageChanges)
        store.stage(makeReview())
        #expect(store.pendingChanges.isEmpty)
    }

    @Test func stageFailsClosedForReadOnlyAndDemo() async throws {
        let readOnlyStore = try await makeEditableStore(adapter: EditingStubAdapter(readOnly: true))
        readOnlyStore.stage(makeReview())
        #expect(readOnlyStore.pendingChanges.isEmpty)

        let demoStore = try await makeEditableStore(adapter: EditingStubAdapter(demo: true))
        demoStore.stage(makeReview())
        #expect(demoStore.pendingChanges.isEmpty)
    }

    /// Cross-table batches are out of scope: a review for another object is
    /// refused.
    @Test func stageRefusesOtherObjects() async throws {
        let store = try await makeEditableStore(
            adapter: EditingStubAdapter(),
            objects: [StubAdapter.table, StubAdapter.otherTable])
        store.stage(makeReview(object: StubAdapter.otherTable))
        #expect(store.pendingChanges.isEmpty)
    }

    @Test func removeAndClear() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        store.stage(makeReview())
        store.stage(makeReview(id: 2))
        let firstID = try #require(store.pendingChanges.first?.id)
        store.removePendingChange(id: firstID)
        #expect(store.pendingChanges.count == 1)
        store.clearPendingChanges()
        #expect(store.pendingChanges.isEmpty)
    }

    // MARK: Apply

    @Test func applyRunsEveryChangeInOrderAndClears() async throws {
        let adapter = EditingStubAdapter()
        let store = try await makeEditableStore(adapter: adapter)
        store.stage(makeReview())
        store.stage(makeReview(id: 2))
        store.stage(makeReview(id: 3))

        #expect(store.canApplyPendingChanges)
        let applied = await store.applyPendingChanges()
        #expect(applied)
        #expect(store.pendingChanges.isEmpty)
        #expect(adapter.applied.count == 3)
        // Order is the staging order.
        #expect(adapter.applied.map { $0.original["name"] } == [
            .string("old1"), .string("old2"), .string("old3"),
        ])
        #expect(store.errorMessage == nil)
    }

    /// Failure policy: stop at the first failure — applied entries are
    /// written and leave the batch; the failed one and the rest stay staged;
    /// the banner reports the honest partial count.
    @Test func applyStopsAtFirstFailureAndReportsPartialProgress() async throws {
        let adapter = EditingStubAdapter()
        adapter.applyErrorSequence = [
            nil,
            AdapterError.notFound("optimistic conflict on row 2"),
            nil,
        ]
        let store = try await makeEditableStore(adapter: adapter)
        store.stage(makeReview())
        store.stage(makeReview(id: 2))
        store.stage(makeReview(id: 3))

        let applied = await store.applyPendingChanges()
        #expect(!applied)
        // One written; the failed change and the one after it stay staged.
        #expect(adapter.applied.count == 1)
        #expect(store.pendingChanges.count == 2)
        #expect(store.pendingChanges[0].review.changed["name"] == .string("new2"))
        #expect(store.errorMessage
            == "Applied 1 of 3 staged changes, then stopped: optimistic conflict on row 2")

        // Retry after the external conflict is resolved: the rest applies.
        let retried = await store.applyPendingChanges()
        #expect(retried)
        #expect(store.pendingChanges.isEmpty)
        #expect(adapter.applied.count == 3)
    }

    @Test func applyFailsClosedWithoutBatchOrGate() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        #expect(!store.canApplyPendingChanges)
        let applied = await store.applyPendingChanges()
        #expect(!applied)
        #expect(store.errorMessage != nil)
    }

    // MARK: Discard semantics

    /// Switching connections discards the batch with a visible notice.
    @Test func connectionSwitchDiscardsWithNotice() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        store.stage(makeReview())
        #expect(store.pendingChanges.count == 1)

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(store.pendingChanges.isEmpty)
        #expect(store.errorMessage == "Discarded 1 staged change — the connection changed.")
    }

    /// Previewing a different object discards the batch with a notice;
    /// re-previewing the same object keeps it.
    @Test func objectSwitchDiscardsButSameObjectKeeps() async throws {
        let adapter = EditingStubAdapter()
        let store = try await makeEditableStore(
            adapter: adapter,
            objects: [StubAdapter.table, StubAdapter.otherTable])
        store.stage(makeReview())

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.previewedObject == StubAdapter.table && !store.isExecuting })
        #expect(store.pendingChanges.count == 1)

        store.preview(StubAdapter.otherTable)
        #expect(await waitUntil { store.previewedObject == StubAdapter.otherTable && !store.isExecuting })
        #expect(store.pendingChanges.isEmpty)
        #expect(store.errorMessage == "Discarded 1 staged change — the previewed object changed.")
    }

    /// Refresh keeps the batch: stale baselines surface as per-item
    /// optimistic conflicts at apply time instead of silent discards.
    @Test func refreshKeepsBatch() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        store.stage(makeReview())
        store.refreshObjects()
        #expect(await waitUntil { !store.isLoadingObjects })
        #expect(store.pendingChanges.count == 1)
    }
}
