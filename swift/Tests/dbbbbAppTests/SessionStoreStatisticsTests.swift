import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// SessionStore gating for table statistics (ROADMAP M2 ⑩): the menu is
/// fail-closed for non-conforming adapters and non-leaf objects, results
/// land in the sheet, failures in the redacted banner.
@MainActor
struct SessionStoreStatisticsTests {
    /// The menu capability is fail-closed: adapters that do not conform to
    /// `SupportsTableStatistics` never offer it.
    @Test func capabilityHiddenForNonConformingAdapter() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(!store.canShowTableStatistics(for: StubAdapter.table))
        store.showTableStatistics(for: StubAdapter.table)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.tableStatistics == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func capabilityRequiresTableViewOrCollection() async throws {
        let store = makeStore()
        let adapter = StatisticsStubAdapter()
        adapter.objects = [StubAdapter.schema, StubAdapter.table, StubAdapter.collection]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        #expect(store.canShowTableStatistics(for: StubAdapter.table))
        #expect(store.canShowTableStatistics(for: StubAdapter.collection))
        #expect(store.canShowTableStatistics(for: StubAdapter.otherTable))
        #expect(!store.canShowTableStatistics(for: StubAdapter.schema))
    }

    @Test func showTableStatisticsPresentsSnapshot() async throws {
        let store = makeStore()
        let adapter = StatisticsStubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showTableStatistics(for: StubAdapter.table)
        #expect(await waitUntil { store.tableStatistics != nil })
        #expect(store.tableStatistics?.objectName == "items")
        #expect(store.tableStatistics?.statistics.estimatedRows == 42)
        #expect(store.tableStatistics?.statistics.totalBytes == 4_096)
        #expect(adapter.statisticsRequests == [StubAdapter.table])
        #expect(store.errorMessage == nil)

        store.dismissTableStatistics()
        #expect(store.tableStatistics == nil)
    }

    /// Fetch failures go through the redacted banner, never into the sheet.
    @Test func showTableStatisticsErrorGoesToBanner() async throws {
        let store = makeStore()
        let adapter = StatisticsStubAdapter()
        adapter.statisticsError = AdapterError.notFound("This object is gone.")
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showTableStatistics(for: StubAdapter.table)
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.errorMessage == "This object is gone.")
        #expect(store.tableStatistics == nil)
    }

    /// Switching connections clears a presented sheet.
    @Test func presentationClearedOnConnectionSwitch() async throws {
        let store = makeStore()
        let adapter = StatisticsStubAdapter()
        adapter.objects = [StubAdapter.table]
        try await addStubSession(to: store, adapter: adapter)
        #expect(await waitUntil { !store.isLoadingObjects })

        store.showTableStatistics(for: StubAdapter.table)
        #expect(await waitUntil { store.tableStatistics != nil })

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(store.tableStatistics == nil)
    }
}
