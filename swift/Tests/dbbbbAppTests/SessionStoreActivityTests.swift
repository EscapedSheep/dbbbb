import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// SessionStore gating for the server-activity viewer (ROADMAP M2 ⑨): the
/// toolbar entry is fail-closed for non-conforming adapters, listing is a
/// read (read-only profiles included), kill requires a writable real
/// profile, and failures surface through the redacted banner.
@MainActor
struct SessionStoreActivityTests {
    /// Non-conforming adapters (SQLite shape) never offer the menu.
    @Test func menuHiddenForNonConformingAdapter() async throws {
        let store = makeStore()
        let adapter = StubAdapter()
        try await addStubSession(to: store, adapter: adapter)

        #expect(!store.canShowServerActivity)
        store.showServerActivity()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(store.serverActivity == nil)
        #expect(store.errorMessage == nil)
    }

    @Test func showServerActivityPresentsSnapshot() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        try await addStubSession(to: store, adapter: adapter)

        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })
        #expect(store.serverActivity?.activities.map(\.id) == ["101", "102"])
        #expect(store.errorMessage == nil)

        // Manual refresh replaces the rows in place.
        adapter.activities = [adapter.activities[0]]
        store.refreshServerActivity()
        #expect(await waitUntil { store.serverActivity?.activities.count == 1 })

        store.dismissServerActivity()
        #expect(store.serverActivity == nil)
    }

    /// Fetch failures go through the redacted banner, never into the sheet.
    @Test func listErrorGoesToBanner() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        adapter.activityError = AdapterError.notFound("The activity list is unavailable.")
        try await addStubSession(to: store, adapter: adapter)

        store.showServerActivity()
        #expect(await waitUntil { store.errorMessage != nil })
        #expect(store.errorMessage == "The activity list is unavailable.")
        #expect(store.serverActivity == nil)
    }

    /// Listing is a read: read-only profiles may list, but kill is disabled
    /// with an explanation.
    @Test func readOnlyProfileMayListButNotKill() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter(readOnly: true)
        try await addStubSession(to: store, adapter: adapter)

        #expect(store.canShowServerActivity)
        #expect(!store.canKillServerActivity)
        #expect(store.killActivityUnavailableReason?.contains("Read-only") == true)

        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })

        let killed = await store.killServerActivity(id: "101")
        #expect(!killed)
        #expect(store.errorMessage?.contains("Read-only") == true)
        #expect(adapter.killRequests.isEmpty)
    }

    /// Demo connections list the canned rows but never offer kill.
    @Test func demoProfileHidesKill() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter(demo: true)
        try await addStubSession(to: store, adapter: adapter)

        #expect(store.canShowServerActivity)
        #expect(!store.canKillServerActivity)
        #expect(store.killActivityUnavailableReason?.contains("Demo") == true)

        let killed = await store.killServerActivity(id: "101")
        #expect(!killed)
        #expect(store.errorMessage?.contains("Demo") == true)
        #expect(adapter.killRequests.isEmpty)
    }

    /// A successful kill reaches the adapter and refreshes the list so the
    /// killed row disappears.
    @Test func killSuccessRemovesTheRow() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        try await addStubSession(to: store, adapter: adapter)

        #expect(store.canKillServerActivity)
        #expect(store.killActivityUnavailableReason == nil)

        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })

        let killed = await store.killServerActivity(id: "101")
        #expect(killed)
        #expect(adapter.killRequests == ["101"])
        #expect(store.serverActivity?.activities.map(\.id) == ["102"])
        #expect(store.errorMessage == nil)
    }

    /// Kill failures surface redacted in the banner.
    @Test func killFailureGoesToBanner() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        adapter.killError = AdapterError.notFound("The operation already finished.")
        try await addStubSession(to: store, adapter: adapter)

        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })

        let killed = await store.killServerActivity(id: "101")
        #expect(!killed)
        #expect(adapter.killRequests == ["101"])
        #expect(store.errorMessage == "The operation already finished.")
        // The failed kill leaves the row listed.
        #expect(store.serverActivity?.activities.map(\.id) == ["101", "102"])
    }

    /// Kill without an open sheet still works (the refresh is skipped).
    @Test func killWithoutOpenSheetStillRuns() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        try await addStubSession(to: store, adapter: adapter)

        let killed = await store.killServerActivity(id: "101")
        #expect(killed)
        #expect(store.serverActivity == nil)
    }

    /// Switching connections clears a presented sheet.
    @Test func presentationClearedOnConnectionSwitch() async throws {
        let store = makeStore()
        let adapter = ActivityStubAdapter()
        try await addStubSession(to: store, adapter: adapter)

        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })

        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(store.serverActivity == nil)
    }

    /// The seeded demo adapters conform: their canned rows are listable.
    @Test func demoAdapterListsFixtureRows() async throws {
        let store = makeStore()
        let demo = try #require(store.sessions.first { $0.profile.demo })
        store.selectConnection(demo.id)
        #expect(await waitUntil { store.canShowServerActivity })
        store.showServerActivity()
        #expect(await waitUntil { store.serverActivity != nil })
        #expect(store.errorMessage == nil)
    }
}
