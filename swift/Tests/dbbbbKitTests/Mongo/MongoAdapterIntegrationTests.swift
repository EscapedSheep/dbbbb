import Foundation
import Testing
import BSON
import Logging
import MongoClient
import MongoKitten
@testable import dbbbbCore
@testable import dbbbbKit

/// Live-server tests, gated on DBBBB_TEST_MONGO_URL (and optionally
/// DBBBB_TEST_MONGO_DB, default "dbbbb_test"). Disabled entirely without the
/// environment variable, so CI and local runs without a server stay green.
struct MongoAdapterIntegrationTests {
    private static var mongoURL: String? {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_URL"], !url.isEmpty else {
            return nil
        }
        return url
    }

    private static func makeAdapter() async throws -> MongoAdapter {
        let url = try #require(mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        return try await MongoAdapter(input: ConnectionInput.MongoInput(
            name: "integration", uri: url, database: database, tls: tls
        ))
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func listPreviewFindAggregate() async throws {
        let adapter = try await Self.makeAdapter()
        let objects = try await adapter.listObjects()
        #expect(objects.contains { $0.kind == .database })
        guard let collection = objects.first(where: { $0.kind == .collection }) else {
            await adapter.close()
            return // test database has no collections; nothing more to verify
        }

        let preview = try await adapter.previewObject(collection)
        guard case .documents(let previewDocs, let previewMeta) = preview else {
            Issue.record("preview must return documents")
            return
        }
        #expect(previewMeta.count == previewDocs.count)
        #expect(previewDocs.count <= 100)

        // find against the collection carried explicitly by the command.
        let found = try await adapter.execute(
            .mongoFind(collection: collection.name, filter: "{}"),
            options: ExecuteOptions(maxRows: 10)
        )
        guard case .documents(let foundDocs, let foundMeta) = found else {
            Issue.record("find must return documents")
            return
        }
        #expect(foundDocs.count <= 10)
        #expect(foundMeta.count == foundDocs.count)

        // read-only aggregate pipeline.
        let aggregated = try await adapter.execute(
            .mongoAggregate(collection: collection.name, pipeline: #"[{"$limit": 5}]"#),
            options: ExecuteOptions(maxRows: 10)
        )
        guard case .documents(let aggregateDocs, _) = aggregated else {
            Issue.record("aggregate must return documents")
            return
        }
        #expect(aggregateDocs.count <= 5)

        // write stages are refused before reaching the server.
        await #expect { @Sendable in
            _ = try await adapter.execute(
                .mongoAggregate(collection: collection.name, pipeline: #"[{"$out": "dbbbb_should_never_exist"}]"#),
                options: ExecuteOptions()
            )
        } throws: { error in
            guard case MongoAdapterError.writeStageRejected = error else { return false }
            return true
        }

        // SQL on a Mongo session is an engine mismatch.
        await #expect { @Sendable in
            _ = try await adapter.execute(.sql("select 1"), options: ExecuteOptions())
        } throws: { error in
            (error as? AdapterError) == .engineMismatch
        }

        await adapter.close()
        await #expect { @Sendable in
            _ = try await adapter.listObjects()
        } throws: { error in
            (error as? AdapterError) == .sessionClosed
        }
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func preRegisteredCancellation() async throws {
        let adapter = try await Self.makeAdapter()
        let objects = try await adapter.listObjects()
        guard let collection = objects.first(where: { $0.kind == .collection }) else {
            await adapter.close()
            return
        }
        _ = try await adapter.previewObject(collection)

        // Cancel a request ID before execute starts: it must fail immediately.
        let options = ExecuteOptions()
        try await adapter.cancel(requestID: options.requestID)
        await #expect { @Sendable in
            _ = try await adapter.execute(.mongoFind(collection: collection.name, filter: "{}"), options: options)
        } throws: { error in
            (error as? MongoAdapterError) == .cancelled
        }
        await adapter.close()
    }

    // MARK: - Editing

    private static let editCollection = "dbbbb_it_edit"
    private static let editToken = "dbbbb_it_edit_token"

    /// Seeds the scratch collection through a plain MongoKitten cluster (the
    /// adapter under test is read-only for ad-hoc commands). Documents are
    /// encoded with dbbbb's own BSON writer so decimal128 and friends can be
    /// constructed exactly.
    private static func seedEditCollection(
        documents: [[(key: String, value: BSONValue)]]
    ) async throws {
        let url = try #require(mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        let uri = try MongoAdapter.effectiveURI(input: ConnectionInput.MongoInput(
            name: "seed", uri: url, database: database, tls: tls))
        let cluster = try await MongoCluster(
            connectingTo: ConnectionSettings(uri),
            logger: Logger(label: "dev.dbbbb.mongodb.test"))
        let collection = cluster[database][editCollection]
        _ = try await collection.deleteAll(where: [:])
        if !documents.isEmpty {
            let encoded = try documents.map { try Document(data: BSONWriter.encode(document: $0)) }
            _ = try await collection.insertMany(encoded)
        }
        await cluster.disconnect()
    }

    private static func editingCollectionObject(
        from objects: [DatabaseObject]
    ) throws -> DatabaseObject {
        let object = try #require(objects.first {
            $0.kind == .collection && $0.name == editCollection
        })
        return object
    }

    private static func documentPairs(_ value: DisplayValue) throws -> [(key: String, value: DisplayValue)] {
        guard case .object(let pairs) = value else {
            Issue.record("expected a document display value, got \(value)")
            throw MongoAdapterError.noCollectionSelected
        }
        return pairs
    }

    private static func findEditDocuments(
        _ adapter: MongoAdapter
    ) async throws -> [[(key: String, value: DisplayValue)]] {
        let result = try await adapter.execute(
            .mongoFind(
                collection: editCollection,
                filter: #"{"token": "\#(editToken)"}"#),
            options: ExecuteOptions(maxRows: 10))
        guard case .documents(let documents, _) = result else {
            Issue.record("find must return documents")
            return []
        }
        return try documents.map { try documentPairs($0) }
    }

    private static func record(
        _ pairs: [(key: String, value: DisplayValue)]
    ) -> [String: DisplayValue] {
        Dictionary(pairs.map { ($0.key, $0.value) }) { first, _ in first }
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func applyDataChangeUpdateConflictAndDelete() async throws {
        let decimalBits = try #require(Decimal128Codec.fromString("0.1"))
        try await Self.seedEditCollection(documents: [[
            ("_id", .objectID(Data(repeating: 0x0C, count: 12))),
            ("token", .string(Self.editToken)),
            ("name", .string("before")),
            ("count", .int32(4)),
            ("note", .null),
            ("big", .int64(9_007_199_254_740_993)),
            ("decimal", .decimal128(low: decimalBits.low, high: decimalBits.high)),
            ("moment", .date(milliseconds: 1_700_000_000_000)),
        ]])

        let adapter = try await Self.makeAdapter()
        let objects = try await adapter.listObjects()
        let collection = try Self.editingCollectionObject(from: objects)

        let found = try await Self.findEditDocuments(adapter)
        #expect(found.count == 1)
        let original = Self.record(found[0])
        // The displayed shapes of the tagged values are the change baseline.
        #expect(original["big"] == .object([("$numberLong", .string("9007199254740993"))]))
        #expect(original["decimal"] == .object([("$numberDecimal", .string("0.1"))]))
        #expect(original["moment"] == .object([("$date", .string("2023-11-14T22:13:20.000Z"))]))

        // Update through the editing capability: tagged values (ObjectId,
        // Decimal128, date, int64, null) must round-trip through the filter
        // or the match would misreport a conflict.
        _ = try await adapter.applyDataChange(DataChange(
            object: collection,
            original: original,
            operation: .update(changed: ["name": .string("after"), "count": .number(8)])))

        let afterUpdate = try await Self.findEditDocuments(adapter)
        #expect(afterUpdate.count == 1)
        let updated = Self.record(afterUpdate[0])
        #expect(updated["name"] == .string("after"))
        #expect(updated["count"] == .number(8))
        #expect(updated["decimal"] == original["decimal"])
        #expect(updated["moment"] == original["moment"])
        #expect(updated["note"] == .null)

        // Replaying the stale baseline is an optimistic-concurrency conflict.
        await #expect { @Sendable in
            _ = try await adapter.applyDataChange(DataChange(
                object: collection,
                original: original,
                operation: .update(changed: ["name": .string("stale")])))
        } throws: { error in
            (error as? dbbbbError)?.userMessage.contains("changed or was deleted") == true
        }

        // Delete with the current baseline, then replay it for the conflict.
        _ = try await adapter.applyDataChange(DataChange(
            object: collection, original: updated, operation: .delete))
        let afterDelete = try await Self.findEditDocuments(adapter)
        #expect(afterDelete.isEmpty)
        await #expect { @Sendable in
            _ = try await adapter.applyDataChange(DataChange(
                object: collection, original: updated, operation: .delete))
        } throws: { error in
            (error as? dbbbbError)?.userMessage.contains("changed or was deleted") == true
        }

        await adapter.close()
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func applyDataChangeRejectsReadOnlySessions() async throws {
        let url = try #require(Self.mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        let adapter = try await MongoAdapter(input: ConnectionInput.MongoInput(
            name: "integration", uri: url, database: database, tls: tls, readOnly: true))

        let object = DatabaseObject(
            id: MongoAdapter.collectionID(for: Self.editCollection, database: database),
            parentID: nil, name: Self.editCollection, kind: .collection)
        await #expect { @Sendable in
            _ = try await adapter.applyDataChange(DataChange(
                object: object,
                original: ["_id": .object([("$oid", .string("0c0c0c0c0c0c0c0c0c0c0c0c"))])],
                operation: .delete))
        } throws: { error in
            (error as? dbbbbError)?.userMessage.contains("read-only") == true
        }
        await adapter.close()
    }

    /// Insert round trip (ROADMAP M1 ③): a document without `_id` gets a
    /// server-generated one, an explicit tagged `_id` keeps its BSON type,
    /// and a duplicate `_id` surfaces the unique-index wording.
    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func applyDataChangeInsert() async throws {
        try await Self.seedEditCollection(documents: [])
        let adapter = try await Self.makeAdapter()
        let objects = try await adapter.listObjects()
        let collection = try Self.editingCollectionObject(from: objects)

        // Missing _id: generated server-side; tagged values keep their type.
        _ = try await adapter.applyDataChange(DataChange(
            object: collection,
            original: [:],
            operation: .insert(values: [
                "token": .string(Self.editToken),
                "name": .string("inserted"),
                "price": .object([("$numberDecimal", .string("0.1"))]),
            ])))
        // Explicit tagged _id.
        _ = try await adapter.applyDataChange(DataChange(
            object: collection,
            original: [:],
            operation: .insert(values: [
                "_id": .object([("$oid", .string("0d0d0d0d0d0d0d0d0d0d0d0d"))]),
                "token": .string(Self.editToken),
            ])))

        let found = try await Self.findEditDocuments(adapter)
        #expect(found.count == 2)
        let records = found.map(Self.record)
        let generated = try #require(records.first { $0["name"] == .string("inserted") })
        #expect(generated["_id"] != nil)
        #expect(generated["price"] == .object([("$numberDecimal", .string("0.1"))]))
        #expect(records.contains {
            $0["_id"] == .object([("$oid", .string("0d0d0d0d0d0d0d0d0d0d0d0d"))])
        })

        // Reinserting the same explicit _id violates the unique index.
        await #expect { @Sendable in
            _ = try await adapter.applyDataChange(DataChange(
                object: collection,
                original: [:],
                operation: .insert(values: [
                    "_id": .object([("$oid", .string("0d0d0d0d0d0d0d0d0d0d0d0d"))]),
                ])))
        } throws: { error in
            (error as? dbbbbError)?.userMessage.contains("unique index") == true
        }

        // Read-only sessions refuse inserts client-side.
        let url = try #require(Self.mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        let readOnlyAdapter = try await MongoAdapter(input: ConnectionInput.MongoInput(
            name: "integration", uri: url, database: database, tls: tls, readOnly: true))
        await #expect { @Sendable in
            _ = try await readOnlyAdapter.applyDataChange(DataChange(
                object: collection,
                original: [:],
                operation: .insert(values: ["token": .string(Self.editToken)])))
        } throws: { error in
            (error as? dbbbbError)?.userMessage.contains("read-only") == true
        }
        await readOnlyAdapter.close()
        await adapter.close()
    }

    // MARK: - Import

    private static let importCollection = "dbbbb_it_import"
    private static let importToken = "dbbbb_it_import_token"

    /// Creates (if needed) and empties the scratch import collection through a
    /// plain MongoKitten cluster.
    private static func wipeImportCollection() async throws {
        let url = try #require(mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        let uri = try MongoAdapter.effectiveURI(input: ConnectionInput.MongoInput(
            name: "seed", uri: url, database: database, tls: tls))
        let cluster = try await MongoCluster(
            connectingTo: ConnectionSettings(uri),
            logger: Logger(label: "dev.dbbbb.mongodb.test"))
        let collection = cluster[database][importCollection]
        // Seeding one document materializes the collection; deleteAll empties it.
        _ = try await collection.insertMany([Document()])
        _ = try await collection.deleteAll(where: [:])
        await cluster.disconnect()
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func importJSONLIntoScratchCollection() async throws {
        try await Self.wipeImportCollection()

        let adapter = try await Self.makeAdapter()
        let objects = try await adapter.listObjects()
        let target = try #require(objects.first {
            $0.kind == .collection && $0.name == Self.importCollection
        })

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-mongo-import-\(UUID().uuidString).jsonl")
        try Data(#"""
            {"token": "dbbbb_it_import_token", "n": 1, "name": "one"}
            {"token": "dbbbb_it_import_token", "big": {"$numberLong": "9007199254740993"}}
            {"token": "dbbbb_it_import_token", "tags": ["a", "b"]}
            """#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let summary = try await adapter.importData(ImportRequest(
            target: target, format: .jsonl, fileURL: file, hasHeader: false))
        #expect(summary == ImportSummary(processed: 3, inserted: 3, failed: 0))

        let found = try await adapter.execute(
            .mongoFind(
                collection: Self.importCollection,
                filter: #"{"token": "dbbbb_it_import_token"}"#),
            options: ExecuteOptions(maxRows: 10))
        guard case .documents(let documents, _) = found else {
            Issue.record("find must return documents")
            await adapter.close()
            return
        }
        #expect(documents.count == 3)

        // A parse failure aborts the import with the line number attached.
        let bad = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-mongo-import-\(UUID().uuidString).jsonl")
        try Data("{\"ok\": 1}\nnot-json\n".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        do {
            _ = try await adapter.importData(ImportRequest(
                target: target, format: .jsonl, fileURL: bad, hasHeader: false))
            Issue.record("expected parseFailure")
        } catch let error as ImportError {
            #expect(error == .parseFailure(detail: "Invalid JSON on JSONL line 2."))
        }

        try await Self.wipeImportCollection()
        await adapter.close()
    }

    @Test(.enabled(if: MongoAdapterIntegrationTests.mongoURL != nil))
    func importRejectsReadOnlySessions() async throws {
        let url = try #require(Self.mongoURL)
        let database = ProcessInfo.processInfo.environment["DBBBB_TEST_MONGO_DB"] ?? "dbbbb_test"
        let tls = url.lowercased().hasPrefix("mongodb+srv://") || url.contains("tls=true")
        let adapter = try await MongoAdapter(input: ConnectionInput.MongoInput(
            name: "integration", uri: url, database: database, tls: tls, readOnly: true))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-mongo-import-\(UUID().uuidString).jsonl")
        try Data("{\"a\": 1}\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let target = DatabaseObject(
            id: MongoAdapter.collectionID(for: Self.importCollection, database: database),
            parentID: nil, name: Self.importCollection, kind: .collection)
        do {
            _ = try await adapter.importData(ImportRequest(
                target: target, format: .jsonl, fileURL: file, hasHeader: false))
            Issue.record("expected unsupported")
        } catch let error as ImportError {
            #expect(error == .unsupported("Import is disabled for read-only MongoDB connections."))
        }
        await adapter.close()
    }
}
