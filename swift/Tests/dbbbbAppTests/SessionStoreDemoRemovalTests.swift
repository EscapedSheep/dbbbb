import Foundation
import Testing
import dbbbbCore
import dbbbbKit
@testable import dbbbbApp

/// Demo connection removal is a persisted preference: removed demos never
/// re-seed on the next launch, untouched demos still appear, and the set
/// lives in UserDefaults (isolated suite in tests).
@MainActor
struct SessionStoreDemoRemovalTests {
    private func makeSuite() -> (UserDefaults, String) {
        let suite = "dbbbb-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeStore(defaults: UserDefaults) -> SessionStore {
        SessionStore(connectionStore: nil, queryLibrary: nil, defaults: defaults)
    }

    @Test func demoIDsAreStablePerEngine() {
        let first = DemoAdapter.demoSessions().map(\.profile.id)
        let second = DemoAdapter.demoSessions().map(\.profile.id)
        #expect(first == second)
        #expect(Set(first).count == first.count)
    }

    @Test func removedDemoDoesNotReseedAcrossLaunches() async throws {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = makeStore(defaults: defaults)
        #expect(store.sessions.filter { $0.profile.demo }.count == 5)

        let victim = try #require(store.sessions.first { $0.profile.engine == .sqlite })
        store.removeConnection(victim.id)
        #expect(!store.sessions.contains { $0.id == victim.id })

        // Simulated relaunch: a fresh store on the same defaults suite.
        let relaunched = makeStore(defaults: defaults)
        let demos = relaunched.sessions.filter { $0.profile.demo }
        #expect(demos.count == 4)
        #expect(!demos.contains { $0.profile.engine == .sqlite })
        #expect(demos.contains { $0.profile.engine == .postgresql })
        #expect(demos.contains { $0.profile.engine == .bullmq })
    }

    @Test func removingMultipleDemosAccumulates() async throws {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = makeStore(defaults: defaults)
        for engine in [DatabaseEngine.sqlite, .mysql, .mongodb] {
            let session = try #require(store.sessions.first { $0.profile.engine == engine })
            store.removeConnection(session.id)
        }

        let relaunched = makeStore(defaults: defaults)
        let demos = relaunched.sessions.filter { $0.profile.demo }
        #expect(demos.map(\.profile.engine) == [.postgresql, .bullmq])
    }

    @Test func removingEveryDemoLeavesAnEmptyList() async throws {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = makeStore(defaults: defaults)
        for session in store.sessions.filter({ $0.profile.demo }) {
            store.removeConnection(session.id)
        }
        #expect(makeStore(defaults: defaults).sessions.isEmpty)
    }

    @Test func duplicateRemovalIsIdempotent() async throws {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = makeStore(defaults: defaults)
        let victim = try #require(store.sessions.first { $0.profile.engine == .sqlite })
        store.removeConnection(victim.id)
        store.removeConnection(victim.id) // no session left: no-op
        #expect(defaults.stringArray(forKey: SessionStore.removedDemoIDsKey)?.count == 1)
    }

    @Test func realConnectionRemovalStaysManifestDriven() async throws {
        let (defaults, suite) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-demo-removal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionStore = ConnectionStore(directory: directory, keychain: InMemoryKeychainStore())
        let store = SessionStore(
            connectionStore: connectionStore, queryLibrary: nil, defaults: defaults)
        let adapter = StubAdapter()
        store.makeAdapter = { _ in adapter }
        try await store.addConnection(.sqlite(.init(name: "Real", filePath: "stub.db")))

        #expect(connectionStore.loadConnections().count == 1)
        store.removeConnection(adapter.profile.id)
        #expect(connectionStore.loadConnections().isEmpty)
        // Real connections never touch the removed-demo preference.
        #expect(defaults.stringArray(forKey: SessionStore.removedDemoIDsKey) == nil)
        // And the demos are unaffected.
        #expect(store.sessions.filter { $0.profile.demo }.count == 5)
    }
}
