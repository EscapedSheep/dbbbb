import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Value-editor commit gating (ROADMAP M3 值编辑器): `valueEditReview` builds
/// the single-field review only under the same conditions as record editing,
/// and refuses truncated values outright.
@MainActor
struct SessionStoreValueEditTests {
    private let columns = [
        ColumnMeta(name: "id", typeName: "int", numeric: true),
        ColumnMeta(name: "body", typeName: "text"),
    ]
    private var row: [(key: String, value: DisplayValue)] {
        [("id", .number(1)), ("body", .string("hello"))]
    }

    /// Loads a preview of the stub table so `editingObject` opens.
    private func makeEditableStore(adapter: StubAdapter) async throws -> SessionStore {
        let store = makeStore()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })
        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil })
        return store
    }

    @Test func reviewBuildsSingleFieldUpdateWithFullRowBaseline() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        let review = try #require(store.valueEditReview(
            column: "body", newValue: .string("edited"), columns: columns, row: row))

        #expect(review.changes.count == 1)
        #expect(review.changes[0].key == "body")
        #expect(review.changes[0].before == .string("hello"))
        #expect(review.changes[0].after == .string("edited"))
        let change = review.dataChange
        #expect(change.object == StubAdapter.table)
        // The whole row crosses as the optimistic-concurrency baseline.
        #expect(change.original == ["id": .number(1), "body": .string("hello")])
        guard case .update(let changed) = change.operation else {
            Issue.record("expected an update")
            return
        }
        #expect(changed == ["body": .string("edited")])
    }

    /// Non-editable sessions (no editing capability, read-only, demo) fail
    /// closed: no review, no write.
    @Test func reviewFailsClosedWithoutEditingGate() async throws {
        let store = try await makeEditableStore(adapter: StubAdapter())
        #expect(store.editingObject == nil)
        #expect(store.valueEditReview(
            column: "body", newValue: .string("edited"), columns: columns, row: row) == nil)
    }

    @Test func reviewFailsClosedForReadOnlyProfile() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter(readOnly: true))
        #expect(store.editingObject == nil)
        #expect(store.valueEditReview(
            column: "body", newValue: .string("edited"), columns: columns, row: row) == nil)
    }

    @Test func unchangedValueProducesNoReview() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        #expect(store.valueEditReview(
            column: "body", newValue: .string("hello"), columns: columns, row: row) == nil)
    }

    @Test func unknownColumnProducesNoReview() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        #expect(store.valueEditReview(
            column: "ghost", newValue: .string("x"), columns: columns, row: row) == nil)
    }

    /// The 8 MiB truncation discipline: an adapter-truncated value is only a
    /// prefix of the real one, so the popup must never silently overwrite the
    /// unseen tail — the review refuses it.
    @Test func truncatedStringProducesNoReview() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        let truncatedRow: [(key: String, value: DisplayValue)] = [
            ("id", .number(1)),
            ("body", .string("prefix …[dbbbb truncated 900 bytes]")),
        ]
        #expect(store.valueEditReview(
            column: "body", newValue: .string("edited"), columns: columns, row: truncatedRow) == nil)
    }

    @Test func truncatedBinaryProducesNoReview() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        var data = Data([0xDE, 0xAD])
        data.append(contentsOf: "…[dbbbb truncated 64 bytes]".utf8)
        let truncatedRow: [(key: String, value: DisplayValue)] = [
            ("id", .number(1)),
            ("body", .binary(data)),
        ]
        #expect(store.valueEditReview(
            column: "body", newValue: .binary(Data([0x01])), columns: columns, row: truncatedRow) == nil)
    }

    /// A complete binary value may be replaced through the hex editor.
    @Test func completeBinaryEditBuildsReview() async throws {
        let store = try await makeEditableStore(adapter: EditingStubAdapter())
        let binaryRow: [(key: String, value: DisplayValue)] = [
            ("id", .number(1)),
            ("body", .binary(Data([0xDE, 0xAD]))),
        ]
        let review = try #require(store.valueEditReview(
            column: "body", newValue: .binary(Data([0x01])), columns: columns, row: binaryRow))
        guard case .update(let changed) = review.dataChange.operation else {
            Issue.record("expected an update")
            return
        }
        #expect(changed == ["body": .binary(Data([0x01]))])
    }
}
