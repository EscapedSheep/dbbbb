import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

@MainActor
struct SessionStoreExecutionTests {
    @Test func staleQueryResultDoesNotLeakAcrossConnections() async throws {
        let store = makeStore()
        let adapterA = StubAdapter(name: "A")
        let adapterB = StubAdapter(name: "B")
        try await addStubSession(to: store, adapter: adapterA)
        try await addStubSession(to: store, adapter: adapterB)
        store.selectConnection(adapterA.profile.id)
        #expect(await waitUntil { !store.isLoadingObjects })

        adapterA.executeDelay = .milliseconds(600)
        store.queryText = "select 1"
        store.runQuery()
        #expect(store.isExecuting)

        store.selectConnection(adapterB.profile.id)
        // The switch cancels the in-flight request and resets execution state.
        #expect(!store.isExecuting)
        #expect(await waitUntil { adapterA.cancelledRequestIDs.count == 1 })

        // A's late completion must not leak into B's screen.
        try? await Task.sleep(for: .milliseconds(800))
        #expect(store.result == nil)
        #expect(store.errorMessage == nil)

        // B can run immediately because isExecuting/activeRequestID were reset.
        store.queryText = "select 1"
        store.runQuery()
        #expect(await waitUntil { store.result != nil })
        #expect(store.errorMessage == nil)
    }

    @Test func stalePreviewResultDoesNotLeakAcrossConnections() async throws {
        let store = makeStore()
        let adapterA = StubAdapter(name: "A")
        let adapterB = StubAdapter(name: "B")
        try await addStubSession(to: store, adapter: adapterA)
        try await addStubSession(to: store, adapter: adapterB)
        store.selectConnection(adapterA.profile.id)
        #expect(await waitUntil { !store.isLoadingObjects })

        adapterA.previewDelay = .milliseconds(600)
        store.preview(StubAdapter.table)
        #expect(store.isExecuting)
        store.selectConnection(adapterB.profile.id)
        #expect(!store.isExecuting)
        #expect(store.previewedObject == nil)

        try? await Task.sleep(for: .milliseconds(800))
        #expect(store.result == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func previewFailureResetsPreviewState() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.result != nil })
        #expect(store.previewedObject == StubAdapter.table)

        adapter.previewError = AdapterError.notFound("No such object.")
        store.preview(StubAdapter.otherTable)
        #expect(await waitUntil { store.errorMessage != nil })
        // The pointer and the orphaned result are reset together.
        #expect(store.previewedObject == nil)
        #expect(store.result == nil)
        #expect(!store.isExecuting)
    }

    @Test func previewCancelGoesThroughRequestIDAndStaysSilent() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.previewDelay = .seconds(30)
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(store.isExecuting)
        #expect(store.previewedObject == StubAdapter.table)

        store.cancelQuery()
        #expect(await waitUntil { !store.isExecuting })
        #expect(store.errorMessage == nil)
        #expect(store.previewedObject == nil)
        #expect(store.result == nil)
        #expect(await waitUntil { adapter.cancelledRequestIDs.count == 1 })
    }

    @Test func queryCancelStaysSilentAndKeepsPreviousResult() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select 1"
        store.runQuery()
        #expect(await waitUntil { store.result != nil })

        adapter.executeDelay = .seconds(30)
        store.runQuery()
        #expect(store.isExecuting)
        store.cancelQuery()
        #expect(await waitUntil { !store.isExecuting })
        #expect(store.errorMessage == nil)
        #expect(store.result != nil)
        #expect(await waitUntil { adapter.cancelledRequestIDs.count == 1 })
    }

    @Test func adapterCancelledErrorsAreSilent() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.executeError = PostgresAdapterError(message: "PostgreSQL query was cancelled.", sqlState: "57014")
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.queryText = "select 1"
        store.runQuery()
        #expect(await waitUntil { !store.isExecuting })
        #expect(store.errorMessage == nil)
        #expect(store.result == nil)
    }

    @Test func isCancellationRecognizesEveryEngineCancelledError() {
        #expect(SessionStore.isCancellation(CancellationError()))
        #expect(SessionStore.isCancellation(PostgresAdapterError(message: "PostgreSQL query was cancelled.", sqlState: "57014")))
        #expect(SessionStore.isCancellation(MySQLAdapterError.cancelled))
        #expect(SessionStore.isCancellation(ImportError.cancelled))
        // Timeouts and real failures still reach the banner.
        #expect(!SessionStore.isCancellation(PostgresAdapterError(message: "PostgreSQL query timed out.", sqlState: "57014")))
        #expect(!SessionStore.isCancellation(MySQLAdapterError.timedOut))
        #expect(!SessionStore.isCancellation(AdapterError.cancellationUnsupported))
        #expect(!SessionStore.isCancellation(AdapterError.readOnlyViolation))
        #expect(!SessionStore.isCancellation(AdapterError.notFound("No such object.")))
    }

    @Test func applyDataChangeRefreshIsStaleGuarded() async throws {
        let store = makeStore()
        let adapter = EditingStubAdapter()
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.preview(StubAdapter.table)
        #expect(await waitUntil { store.previewedObject == StubAdapter.table })

        adapter.applyDelay = .milliseconds(400)
        async let applied = store.applyDataChange(
            DataChange(object: StubAdapter.table, original: [:], operation: .delete))
        try? await Task.sleep(for: .milliseconds(50))
        store.selectConnection(store.sessions.first { $0.profile.demo }!.id)

        #expect(await applied)
        // The post-apply refresh must not write into the new connection's screen.
        #expect(store.result == nil)
        #expect(store.errorMessage == nil)
    }
}
