import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
final class ProgressBox {
    var values: [ImportProgress] = []
}

@MainActor
struct SessionStoreImportTests {
    @Test func startImportIgnoresReentryWhileRunning() async throws {
        let store = makeStore()
        let adapter = ImportingStubAdapter()
        adapter.importDelay = .milliseconds(400)
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.importingObject == StubAdapter.table })

        let fileURL = URL(fileURLWithPath: "/tmp/dbbbb-app-tests-import.csv")
        store.startImport(format: .csv, fileURL: fileURL, hasHeader: true)
        #expect(store.isImporting)

        store.startImport(format: .csv, fileURL: fileURL, hasHeader: true)
        #expect(store.errorMessage == nil)

        #expect(await waitUntil { !store.isImporting })
        #expect(adapter.importCallCount == 1)
        #expect(store.importSummary == ImportSummary(processed: 2, inserted: 2, failed: 0))
        #expect(store.errorMessage == nil)
    }

    @Test func cancelledImportStaysSilent() async throws {
        let store = makeStore()
        let adapter = ImportingStubAdapter()
        adapter.importDelay = .seconds(30)
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.importingObject == StubAdapter.table })

        store.startImport(format: .csv, fileURL: URL(fileURLWithPath: "/tmp/dbbbb-app-tests-import.csv"), hasHeader: true)
        #expect(store.isImporting)
        store.cancelImport()
        #expect(await waitUntil { !store.isImporting })
        #expect(store.importSummary == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func importProgressRelayCoalescesBursts() async {
        let relay = ImportProgressRelay()
        let box = ProgressBox()
        // A synchronous burst never yields the main actor, so exactly one hop runs.
        for i in 1...100 {
            relay.send(ImportProgress(processed: i, inserted: i, failed: 0, bytes: i)) { box.values.append($0) }
        }
        #expect(await waitUntil { !box.values.isEmpty })
        #expect(box.values.count == 1)
        #expect(box.values.last == ImportProgress(processed: 100, inserted: 100, failed: 0, bytes: 100))
    }

    @Test func importProgressRelayDeliversInOrderAcrossTurns() async {
        let relay = ImportProgressRelay()
        let box = ProgressBox()
        relay.send(ImportProgress(processed: 1)) { box.values.append($0) }
        #expect(await waitUntil { box.values.count == 1 })
        relay.send(ImportProgress(processed: 2)) { box.values.append($0) }
        #expect(await waitUntil { box.values.count == 2 })
        relay.send(ImportProgress(processed: 3)) { box.values.append($0) }
        #expect(await waitUntil { box.values.count == 3 })
        #expect(box.values.map(\.processed) == [1, 2, 3])
    }
}
