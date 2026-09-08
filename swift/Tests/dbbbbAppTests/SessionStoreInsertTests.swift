import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Insert flow (ROADMAP M1 ③): the blank Add Row draft and the prefilled
/// Duplicate Row draft enforce the same fail-closed gates as editing
/// (demo/read-only/non-preview never open the sheet), primary-key columns
/// stay blank on a duplicate, and an introspection failure surfaces in the
/// banner instead of opening a draft.
@MainActor
struct SessionStoreInsertTests {
    private func makePreviewingStore(adapter: StubAdapter) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        return store
    }

    private func previewAndSettle(_ store: SessionStore, _ object: DatabaseObject) async {
        store.preview(object)
        #expect(await waitUntil { store.previewedObject == object && store.result != nil })
    }

    private func editingDraft(_ store: SessionStore) -> RecordDraft? {
        guard case .editing(let draft) = store.recordEditingState else { return nil }
        return draft
    }

    @Test func beginInsertFailsClosedForDemoReadOnlyAndNonPreviewSessions() async throws {
        // Demo profile: capable adapter, still no insert.
        let demoAdapter = EditingStubAdapter(demo: true)
        let demoStore = try await makePreviewingStore(adapter: demoAdapter)
        await previewAndSettle(demoStore, StubAdapter.table)
        demoStore.beginInsert()
        #expect(demoStore.recordEditingState == nil)

        // Read-only profile.
        let readOnlyAdapter = EditingStubAdapter(readOnly: true)
        let readOnlyStore = try await makePreviewingStore(adapter: readOnlyAdapter)
        await previewAndSettle(readOnlyStore, StubAdapter.table)
        readOnlyStore.beginInsert()
        #expect(readOnlyStore.recordEditingState == nil)

        // No preview (ad-hoc result state): no known single change target.
        let adapter = EditingStubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)
        #expect(store.previewedObject == nil)
        store.beginInsert()
        #expect(store.recordEditingState == nil)

        // Adapter without the editing capability fails closed too.
        let plain = StubAdapter()
        let plainStore = try await makePreviewingStore(adapter: plain)
        await previewAndSettle(plainStore, StubAdapter.table)
        plainStore.beginInsert()
        #expect(plainStore.recordEditingState == nil)
    }

    @Test func beginInsertOpensBlankDraftFromInsertableColumns() async throws {
        let adapter = EditingStubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table)

        store.beginInsert()
        #expect(await waitUntil { store.recordEditingState != nil })

        let draft = try #require(editingDraft(store))
        #expect(draft.isInsert)
        #expect(!draft.isDocument)
        #expect(draft.original.isEmpty)
        #expect(draft.object == StubAdapter.table)
        // Every insertable column is seeded blank (.null → NULL toggle on);
        // at review time those fields are omitted so column defaults apply.
        #expect(draft.insertPrefill?.map(\.key) == ["id", "name"])
        #expect(draft.insertPrefill?.allSatisfy { $0.value == .null } == true)
    }

    @Test func beginDuplicatePrefillsRowValuesButBlanksPrimaryKeys() async throws {
        let adapter = EditingStubAdapter()
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table)

        store.beginDuplicate(row: [(key: "id", value: .number(7)), (key: "name", value: .string("ada"))])
        #expect(await waitUntil { store.recordEditingState != nil })

        let draft = try #require(editingDraft(store))
        #expect(draft.isInsert)
        // The primary key stays blank so the server default applies instead
        // of colliding with the source row's unique key.
        #expect(draft.insertPrefill?.first(where: { $0.key == "id" })?.value == .null)
        #expect(draft.insertPrefill?.first(where: { $0.key == "name" })?.value == .string("ada"))
    }

    @Test func beginInsertIntrospectionFailureShowsBannerAndOpensNoDraft() async throws {
        let adapter = EditingStubAdapter()
        adapter.insertableColumnsError = AdapterError.sessionClosed
        let store = try await makePreviewingStore(adapter: adapter)
        await previewAndSettle(store, StubAdapter.table)

        store.beginInsert()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.recordEditingState == nil)
    }

    @Test func beginInsertOnMongoCollectionOpensTheDocumentEditor() async throws {
        let adapter = EditingStubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        let store = makeStore()
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        store.preview(StubAdapter.collection)
        #expect(await waitUntil { store.previewedObject == StubAdapter.collection })

        store.beginInsert()
        let draft = try #require(editingDraft(store))
        #expect(draft.isInsert)
        #expect(draft.isDocument)
        // Documents have no fixed columns — no introspection round trip.
        #expect(draft.columns.isEmpty)
    }

    /// The insert apply path is the editing path: fail-closed gate, then a
    /// re-preview that keeps the current page/sort/filter.
    @Test func applyInsertRefreshesPreviewAtCurrentPage() async throws {
        let adapter = EditingStubAdapter()
        adapter.previewTruncated = true
        let store = try await makePreviewingStore(adapter: adapter)
        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil })
        let sort = PreviewRequest.Sort(column: "id", ascending: false)
        store.setPreviewSort(sort)
        #expect(await waitUntil { adapter.previewRequests.count == 2 })
        store.nextPreviewPage()
        #expect(await waitUntil { adapter.previewRequests.count == 3 })

        let applied = await store.applyDataChange(DataChange(
            object: StubAdapter.table,
            original: [:],
            operation: .insert(values: ["name": .string("new")])))
        #expect(applied)

        guard case .insert(let values) = adapter.applied.last?.operation else {
            Issue.record("expected an insert change to reach the adapter")
            return
        }
        #expect(values == ["name": .string("new")])
        let request = try #require(adapter.previewRequests.last)
        #expect(request.offset == SessionStore.previewPageSize)
        #expect(request.sort == sort)
    }
}
