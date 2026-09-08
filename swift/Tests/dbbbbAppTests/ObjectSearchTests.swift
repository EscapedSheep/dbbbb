import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit
@testable import dbbbbApp

/// Object navigator quick search: the pure tree filter (hit keeps its path,
/// no hit empties the tree, matching is case-insensitive) and its wiring over
/// the store's real `objectTree`.
@MainActor
struct ObjectSearchTests {
    private func node(_ name: String, _ children: [SessionStore.ObjectNode]? = nil) -> SessionStore.ObjectNode {
        SessionStore.ObjectNode(
            object: DatabaseObject(id: name, parentID: nil, name: name, kind: children == nil ? .table : .schema),
            children: children)
    }

    private func names(_ nodes: [SessionStore.ObjectNode]) -> [String] {
        nodes.map { $0.object.name }
    }

    private var fixture: [SessionStore.ObjectNode] {
        [
            node("public", [
                node("users"), node("user_sessions"), node("orders"),
            ]),
            node("analytics", [
                node("daily_users"), node("events"),
            ]),
        ]
    }

    /// A hit keeps every ancestor on its path; sibling branches without a hit
    /// are pruned.
    @Test func hitKeepsAncestorChain() {
        let filtered = ObjectTreeFilter.filter(fixture, query: "sessions")
        #expect(names(filtered) == ["public"])
        #expect(names(filtered[0].children ?? []) == ["user_sessions"])
    }

    /// A hit keeps its whole subtree (context below the hit).
    @Test func hitKeepsSubtree() {
        let filtered = ObjectTreeFilter.filter(fixture, query: "analytics")
        #expect(names(filtered) == ["analytics"])
        #expect(names(filtered[0].children ?? []) == ["daily_users", "events"])
    }

    /// Hits in several subtrees keep all of their paths. ("user_sessions"
    /// contains "user", not "users", so it is pruned here.)
    @Test func hitsAcrossBranches() {
        let filtered = ObjectTreeFilter.filter(fixture, query: "users")
        #expect(names(filtered) == ["public", "analytics"])
        #expect(names(filtered[0].children ?? []) == ["users"])
        #expect(names(filtered[1].children ?? []) == ["daily_users"])
    }

    @Test func noHitEmptiesTree() {
        #expect(ObjectTreeFilter.filter(fixture, query: "nonexistent").isEmpty)
    }

    @Test func matchingIsCaseInsensitive() {
        let filtered = ObjectTreeFilter.filter(fixture, query: "DAILY_USERS")
        #expect(names(filtered) == ["analytics"])
        #expect(names(filtered[0].children ?? []) == ["daily_users"])
    }

    /// Empty/whitespace queries are "no filter": the tree passes through.
    @Test func emptyQueryReturnsTreeUnchanged() {
        #expect(names(ObjectTreeFilter.filter(fixture, query: "")) == ["public", "analytics"])
        #expect(names(ObjectTreeFilter.filter(fixture, query: "   ")) == ["public", "analytics"])
    }

    /// The filter composes with the store's real object tree built from the
    /// adapter's flat object list.
    @Test func filtersStoreObjectTree() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [
            DatabaseObject(id: "s1", parentID: nil, name: "main", kind: .schema),
            DatabaseObject(id: "t1", parentID: "s1", name: "items", kind: .table),
            DatabaseObject(id: "t2", parentID: "s1", name: "orders", kind: .table),
        ]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { store.objects.count == 3 })

        let filtered = ObjectTreeFilter.filter(store.objectTree, query: "ORD")
        #expect(names(filtered) == ["main"])
        #expect(names(filtered[0].children ?? []) == ["orders"])

        #expect(ObjectTreeFilter.filter(store.objectTree, query: "zzz").isEmpty)
        #expect(names(ObjectTreeFilter.filter(store.objectTree, query: "")) == ["main"])
    }
}

/// The clipboard exit for "Copy as INSERT": the qualified table name is
/// recovered from the adapter-issued object id, and fail-closed values throw
/// (the view routes the pre-redacted message to the error banner).
@MainActor
struct CopyInsertFormattingTests {
    private func columns(_ names: [String]) -> [ColumnMeta] {
        names.map { ColumnMeta(name: $0, typeName: "text") }
    }

    /// Ids that do not decode (demo fixtures) fall back to the bare name,
    /// quoted as one identifier.
    @Test func bareNameFallback() throws {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
        let text = try DisplayFormatting.insertStatements(
            rows: [[.number(1), .string("it's")]],
            columns: columns(["id", "name"]),
            object: object, engine: .sqlite)
        #expect(text == #"INSERT INTO "items" ("id", "name") VALUES (1, 'it''s');"#)
    }

    @Test func postgresQualifiedName() throws {
        let ref = PostgresObjectRef(kind: .table, schema: "app", name: "users")
        let object = DatabaseObject(
            id: PostgresObjectIDCodec.encode(ref), parentID: nil, name: "users", kind: .table)
        let text = try DisplayFormatting.insertStatements(
            rows: [[.bool(true), .null]],
            columns: columns(["active", "deleted_at"]),
            object: object, engine: .postgresql)
        #expect(text == #"INSERT INTO "app"."users" ("active", "deleted_at") VALUES (TRUE, NULL);"#)
    }

    /// Fail closed: nothing renderable, nothing copied.
    @Test func binaryFailsClosed() {
        let object = DatabaseObject(id: "t1", parentID: nil, name: "items", kind: .table)
        #expect(throws: ResultExportError.unsupportedValue) {
            try DisplayFormatting.insertStatements(
                rows: [[.binary(Data([0x00]))]],
                columns: columns(["blob"]),
                object: object, engine: .sqlite)
        }
    }
}
