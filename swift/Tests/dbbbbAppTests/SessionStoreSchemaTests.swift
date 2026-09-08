import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
struct SessionStoreSchemaTests {
    private func makeSchema(object: DatabaseObject) -> TableSchema {
        TableSchema(
            object: object,
            columns: [
                ColumnSchema(name: "id", dataType: "INTEGER", nullable: false, primaryKeyOrdinal: 1),
                ColumnSchema(name: "name", dataType: "TEXT", nullable: true, primaryKeyOrdinal: 0),
            ],
            foreignKeys: [],
            indexes: [IndexSchema(name: "items_id_pk", columns: ["id"], isUnique: true)])
    }

    /// The toolbar capability is fail-closed: adapters that do not conform to
    /// `SupportsSchemaIntrospection` (MongoDB among them) never offer it.
    @Test func capabilityHiddenForNonConformingAdapter() async throws {
        let store = makeStore()
        let adapter = StubAdapter(engine: .mongodb)
        adapter.objects = [StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(!store.canShowSchema)
        store.showSchema()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.schemaPresentation == nil)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoadingSchema)
    }

    @Test func showSchemaPresentsTablesAndRelations() async throws {
        let store = makeStore()
        let adapter = SchemaStubAdapter()
        adapter.objects = [StubAdapter.schema, StubAdapter.table, StubAdapter.otherTable]
        adapter.schemaResults = [
            makeSchema(object: StubAdapter.table),
            makeSchema(object: StubAdapter.otherTable),
        ]
        let edge = TableRelation(
            object: StubAdapter.otherTable,
            foreignKey: ForeignKey(
                columns: ["item_id"],
                referencedObject: StubAdapter.table,
                referencedColumns: ["id"]))
        adapter.relationResult = [edge]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(store.canShowSchema)
        store.showSchema()
        #expect(await waitUntil { store.schemaPresentation != nil })

        let presentation = try #require(store.schemaPresentation)
        #expect(presentation.databaseName == "stub")
        // Schema/database nodes are not tables and are never introspected.
        #expect(presentation.tables.map(\.object.name) == ["items", "orders"])
        #expect(adapter.requestedSchemas == [StubAdapter.table, StubAdapter.otherTable])
        #expect(presentation.tables[0].columns.count == 2)
        #expect(presentation.tables[0].indexes.count == 1)
        #expect(presentation.relations == [edge])
        #expect(adapter.relationRequestCount == 1)
        #expect(store.errorMessage == nil)
        #expect(!store.isLoadingSchema)

        store.dismissSchema()
        #expect(store.schemaPresentation == nil)
    }

    /// Fetch failures go through the redacted banner, never into the sheet.
    @Test func showSchemaErrorGoesToBanner() async throws {
        let store = makeStore()
        let adapter = SchemaStubAdapter()
        adapter.objects = [StubAdapter.table]
        adapter.schemaResults = [makeSchema(object: StubAdapter.table)]
        adapter.relationsError = AdapterError.notFound("The schema could not be read.")
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showSchema()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.errorMessage == "The schema could not be read.")
        #expect(store.schemaPresentation == nil)
        #expect(!store.isLoadingSchema)
    }

    /// Switching connections clears a presented sheet.
    @Test func presentationClearedOnConnectionSwitch() async throws {
        let store = makeStore()
        let adapter = SchemaStubAdapter()
        adapter.objects = [StubAdapter.table]
        adapter.schemaResults = [makeSchema(object: StubAdapter.table)]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showSchema()
        #expect(await waitUntil { store.schemaPresentation != nil })

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(store.schemaPresentation == nil)
    }
}
