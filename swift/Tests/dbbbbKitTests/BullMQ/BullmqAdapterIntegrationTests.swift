import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit

/// Live-Redis coverage for the BullMQ adapter, gated on DBBBB_TEST_REDIS_URL
/// (skipped without it, like the MongoDB integration suite). Fixture data is
/// seeded by hand with raw commands through our own `RedisConnection`, in the
/// exact key layout BullMQ writes (hash fields incl. the `atm` short key,
/// per-state indexes, a colon-named queue).
///
/// Safety: everything lives under the dedicated `dbbbits` prefix on logical
/// database 15; cleanup only SCANs and DELetes keys matching that prefix.
/// FLUSHDB/FLUSHALL are never used. The suite is serialized: all tests share
/// the one prefix on db 15 and must not seed/clean concurrently.
@Suite(.serialized)
struct BullmqAdapterIntegrationTests {
    private static let redisURL: String? = {
        guard let url = ProcessInfo.processInfo.environment["DBBBB_TEST_REDIS_URL"], !url.isEmpty else {
            return nil
        }
        return url
    }()

    private static let redisDB = 15
    private static let prefix = "dbbbits"
    private static let queue = "it-emails"
    private static let colonQueue = "it:reports"
    private static let pausedQueue = "it-paused"
    private static let flowQueue = "it-flow"
    private static let base: Double = 1_756_490_000_000

    // MARK: - Harness

    private static func hostPort() throws -> (host: String, port: Int) {
        let raw = try #require(redisURL)
        guard let url = URL(string: raw), let host = url.host else {
            throw BullmqAdapterError.invalidConfiguration
        }
        return (host, url.port ?? 6379)
    }

    private static func makeClient() throws -> RedisConnection {
        let (host, port) = try hostPort()
        return RedisConnection(host: host, port: port, database: redisDB)
    }

    private static func makeAdapter(client: (any RedisClienting)? = nil, fetcher: (any BullmqPageFetching)? = nil) throws -> BullmqAdapter {
        let (host, port) = try hostPort()
        let input = ConnectionInput.BullmqInput(
            name: "integration", host: host, port: port,
            database: redisDB, tls: false, prefix: prefix, readOnly: true)
        if let client {
            return try BullmqAdapter(input: input, client: client, fetcher: fetcher)
        }
        return try BullmqAdapter(input: input)
    }

    /// SCAN + DEL of only our own prefix; never FLUSH.
    private static func cleanup(_ client: RedisConnection) async throws {
        var cursor = "0"
        repeat {
            let reply = try await client.scan(cursor: cursor, match: "\(prefix):*", count: 500)
            if !reply.keys.isEmpty {
                _ = try await client.command(["DEL"] + reply.keys)
            }
            cursor = reply.nextCursor
        } while cursor != "0"
    }

    /// Seeds, runs the body against a connected Lua-fetcher adapter, and
    /// always cleans the prefix back up (pass or fail).
    private static func run(
        seed: (RedisConnection) async throws -> Void = { _ in },
        _ body: (BullmqAdapter) async throws -> Void
    ) async throws {
        let client = try makeClient()
        try await client.connect()
        try await cleanup(client)
        do {
            try await seed(client)
            let adapter = try makeAdapter()
            try await adapter.connect()
            do {
                try await body(adapter)
            } catch {
                await adapter.close()
                try? await cleanup(client)
                await client.disconnect()
                throw error
            }
            await adapter.close()
        } catch {
            try? await cleanup(client)
            await client.disconnect()
            throw error
        }
        try await cleanup(client)
        await client.disconnect()
        // The prefix must be gone after every test (full SCAN sweep).
        let verify = try makeClient()
        try await verify.connect()
        var leftovers: [String] = []
        var cursor = "0"
        repeat {
            let reply = try await verify.scan(cursor: cursor, match: "\(prefix):*", count: 500)
            leftovers.append(contentsOf: reply.keys)
            cursor = reply.nextCursor
        } while cursor != "0"
        await verify.disconnect()
        #expect(leftovers.isEmpty, "cleanup left keys behind: \(leftovers)")
    }

    // MARK: - Seed helpers

    private static func hset(_ client: RedisConnection, _ key: String, _ fields: [String: String]) async throws {
        var command = ["HSET", key]
        for (field, value) in fields.sorted(by: { $0.key < $1.key }) {
            command.append(field)
            command.append(value)
        }
        _ = try await client.command(command)
    }

    private static func zadd(_ client: RedisConnection, _ key: String, _ score: Double, _ member: String) async throws {
        _ = try await client.command(["ZADD", key, BullmqJSON.numberString(score), member])
    }

    private static func rpush(_ client: RedisConnection, _ key: String, _ members: [String]) async throws {
        _ = try await client.command(["RPUSH", key] + members)
    }

    /// The full four-queue fixture mirroring the Electron integration suite.
    private static func seedAll(_ client: RedisConnection) async throws {
        // Colon-named queue (bullmq itself forbids colons, but such keys exist
        // in the wild from older versions and hand-rolled producers).
        _ = try await client.command(["SET", "\(prefix):\(colonQueue):id", "2"])
        try await hset(client, "\(prefix):\(colonQueue):1", [
            "name": "weekly-report",
            "data": #"{"report":{"kind":"weekly"}}"#,
            "attemptsMade": "1",
            "timestamp": number(base - 10_000),
            "processedOn": number(base - 9_000),
            "finishedOn": number(base - 8_000),
        ])
        try await zadd(client, "\(prefix):\(colonQueue):completed", base - 8_000, "1")
        try await hset(client, "\(prefix):\(colonQueue):2", [
            "name": "nightly-report",
            "data": #"{"report":{"kind":"nightly"}}"#,
            "attemptsMade": "5",
            "failedReason": "Upstream API returned 502",
            "stacktrace": #"["Error: Upstream API returned 502"]"#,
            "timestamp": number(base - 5_000),
            "processedOn": number(base - 4_000),
            "finishedOn": number(base - 3_000),
        ])
        try await zadd(client, "\(prefix):\(colonQueue):failed", base - 3_000, "2")

        // it-emails: 6 completed, 4 failed, 2 waiting, 2 delayed, 2 prioritized.
        _ = try await client.command(["SET", "\(prefix):\(queue):id", "16"])
        for index in 0..<6 {
            let id = String(index + 1)
            let name = index % 3 == 2 ? "invoice-email" : "welcome-email"
            let tier = index % 2 == 0 ? "pro" : "free"
            let finished = base + Double(index) * 1_000
            try await hset(client, "\(prefix):\(queue):\(id)", [
                "name": name,
                "data": #"{"userId":\#(index + 1),"user":{"id":\#(index + 1),"tier":"\#(tier)"}}"#,
                "opts": #"{"attempts":1}"#,
                "atm": "1",
                "timestamp": number(finished - 2_000),
                "processedOn": number(finished - 1_000),
                "finishedOn": number(finished),
            ])
            try await zadd(client, "\(prefix):\(queue):completed", finished, id)
            if name == "invoice-email" {
                try await rpush(client, "\(prefix):\(queue):\(id):logs", ["rendering invoice", "sent through smtp"])
            }
        }
        for index in 0..<4 {
            let id = String(index + 7)
            let name = index % 2 == 0 ? "welcome-email" : "invoice-email"
            let finished = base + 50_000 + Double(index) * 1_000
            try await hset(client, "\(prefix):\(queue):\(id)", [
                "name": name,
                "data": #"{"userId":\#(100 + index),"user":{"id":\#(100 + index),"tier":"pro"},"shouldFail":true}"#,
                "opts": #"{"attempts":1}"#,
                "atm": "1",
                "failedReason": "SMTP rejected recipient for \(name)",
                "stacktrace": #"["Error: SMTP rejected recipient for \#(name)","    at send (mail.js:1)"]"#,
                "timestamp": number(finished - 2_000),
                "processedOn": number(finished - 1_000),
                "finishedOn": number(finished),
            ])
            try await zadd(client, "\(prefix):\(queue):failed", finished, id)
        }
        for index in 0..<2 {
            let id = String(index + 11)
            try await hset(client, "\(prefix):\(queue):\(id)", [
                "name": "digest-email",
                "data": #"{"userId":\#(200 + index),"user":{"id":\#(200 + index),"tier":"team"}}"#,
                "timestamp": number(base + 60_000 + Double(index)),
            ])
        }
        try await rpush(client, "\(prefix):\(queue):wait", ["11", "12"])
        for index in 0..<2 {
            let id = String(index + 13)
            try await hset(client, "\(prefix):\(queue):\(id)", [
                "name": "reminder-email",
                "data": #"{"userId":\#(300 + index),"user":{"id":\#(300 + index),"tier":"free"}}"#,
                "delay": "600000",
                "timestamp": number(base + 70_000 + Double(index)),
            ])
            try await zadd(client, "\(prefix):\(queue):delayed", base + 600_000 + Double(index), id)
        }
        // Priority > 0 parks jobs in the prioritized zset, whose score packs
        // the priority into the high bits (priority × 2^32 + job counter) —
        // not a plain timestamp.
        let pack = { (priority: Double, counter: Double) in priority * 4_294_967_296 + counter }
        try await hset(client, "\(prefix):\(queue):15", [
            "name": "urgent-email",
            "data": #"{"userId":401,"user":{"id":401,"tier":"pro"}}"#,
            "timestamp": number(base + 80_000),
        ])
        try await zadd(client, "\(prefix):\(queue):prioritized", pack(5, 15), "15")
        try await hset(client, "\(prefix):\(queue):16", [
            "name": "urgent-email",
            "data": #"{"userId":402,"user":{"id":402,"tier":"pro"}}"#,
            "timestamp": number(base + 85_000),
        ])
        try await zadd(client, "\(prefix):\(queue):prioritized", pack(2, 16), "16")

        // Legacy paused list (bullmq 6 no longer writes it; older producers do).
        _ = try await client.command(["SET", "\(prefix):\(pausedQueue):id", "2"])
        for index in 0..<2 {
            try await hset(client, "\(prefix):\(pausedQueue):\(index + 1)", [
                "name": "paused-task",
                "data": #"{"userId":\#(500 + index)}"#,
                "timestamp": number(base + 90_000 + Double(index) * 1_000),
            ])
        }
        try await rpush(client, "\(prefix):\(pausedQueue):paused", ["1", "2"])

        // A flow parent parked in waiting-children (timestamp score).
        _ = try await client.command(["SET", "\(prefix):\(flowQueue):id", "1"])
        try await hset(client, "\(prefix):\(flowQueue):1", [
            "name": "parent-report",
            "data": #"{"part":"parent"}"#,
            "timestamp": number(base + 100_000),
        ])
        try await zadd(client, "\(prefix):\(flowQueue):waiting-children", base + 100_000, "1")
    }

    private static func number(_ value: Double) -> String {
        BullmqJSON.numberString(value)
    }

    private static func executeJobs(
        _ adapter: BullmqAdapter, _ queryJSON: String, requestID: UUID = UUID()
    ) async throws -> (documents: [DisplayValue], meta: ResultMeta) {
        let result = try await adapter.execute(
            .bullmqJobs(queryJSON),
            options: ExecuteOptions(requestID: requestID, timeout: .seconds(10), maxRows: 500, maxBytes: 5 * 1024 * 1024))
        guard case .documents(let documents, let meta) = result else {
            Issue.record("Expected a document result.")
            return ([], ResultMeta(count: 0, truncated: false, elapsedMilliseconds: 0))
        }
        return (documents, meta)
    }

    private static func field(_ document: DisplayValue, _ key: String) -> DisplayValue? {
        guard case .object(let pairs) = document else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }

    private static func stringField(_ document: DisplayValue, _ key: String) -> String? {
        guard case .string(let value)? = field(document, key) else { return nil }
        return value
    }

    private static func numberField(_ document: DisplayValue, _ key: String) -> Double? {
        guard case .number(let value)? = field(document, key) else { return nil }
        return value
    }

    // MARK: - Tests

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func discoversQueuesAndReportsRealPerStateCounts() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let nodes = try await adapter.listObjects()
            let queues = nodes.filter { $0.kind == .collection }.map(\.id)
            #expect(Set(queues) == [Self.queue, Self.colonQueue, Self.flowQueue, Self.pausedQueue])

            let emails = Dictionary(uniqueKeysWithValues: nodes
                .filter { $0.parentID == Self.queue }
                .map { ($0.name, $0.detail) })
            #expect(emails.count == 8)
            #expect(emails["completed"] == "6 jobs")
            #expect(emails["failed"] == "4 jobs")
            #expect(emails["waiting"] == "2 jobs")
            #expect(emails["delayed"] == "2 jobs")
            #expect(emails["prioritized"] == "2 jobs")
            #expect(emails["active"] == "0 jobs")
            #expect(nodes.first { $0.id == "\(Self.colonQueue):failed" }?.detail == "1 job")
            #expect(nodes.first { $0.id == "\(Self.pausedQueue):paused" }?.detail == "2 jobs")
            #expect(nodes.first { $0.id == "\(Self.flowQueue):waiting-children" }?.detail == "1 job")
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func previewsQueueAndStateNodesColonNamedQueueIncluded() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let nodes = try await adapter.listObjects()
            let queueNode = try #require(nodes.first { $0.id == Self.colonQueue })
            let queuePreview = try await adapter.previewObject(PreviewRequest(object: queueNode))
            guard case .documents(let documents, _) = queuePreview else {
                Issue.record("preview must return documents")
                return
            }
            // Queue nodes preview the failed state.
            #expect(documents.count == 1)
            #expect(documents.allSatisfy { Self.stringField($0, "state") == "failed" })

            let stateNode = try #require(nodes.first { $0.id == "\(Self.colonQueue):completed" })
            let statePreview = try await adapter.previewObject(PreviewRequest(object: stateNode))
            guard case .documents(let completed, _) = statePreview else {
                Issue.record("preview must return documents")
                return
            }
            #expect(completed.count == 1)
            #expect(Self.stringField(try #require(completed.first), "name") == "weekly-report")
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func returnsFailedJobsWithReasonAndStacktrace() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let result = try await Self.executeJobs(adapter, #"{"queue":"it-emails","state":"failed"}"#)
            #expect(result.documents.count == 4)
            #expect(result.meta.total == 4)
            #expect(!result.meta.truncated)
            for document in result.documents {
                #expect(Self.stringField(document, "queue") == Self.queue)
                #expect(Self.stringField(document, "state") == "failed")
                #expect(Self.stringField(document, "failedReason")?.contains("SMTP rejected recipient") == true)
                guard case .array(let stacktrace)? = Self.field(document, "stacktrace") else {
                    Issue.record("stacktrace must be an array")
                    return
                }
                #expect(!stacktrace.isEmpty)
                #expect(Self.numberField(document, "attemptsMade") != nil)
                #expect(Self.numberField(document, "timestamp") != nil)
                #expect(Self.numberField(document, "finishedOn") != nil)
            }
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func filtersCompletedJobsByFinishedOnTimeRange() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let all = try await Self.executeJobs(adapter, #"{"queue":"it-emails","state":"completed"}"#)
            #expect(all.documents.count == 6)
            let earliest = all.documents.compactMap { Self.numberField($0, "finishedOn") }.min()
            let earliestText = Self.number(try #require(earliest))

            let ranged = try await Self.executeJobs(
                adapter,
                #"{"queue":"it-emails","state":"completed","from":\#(earliestText),"to":\#(earliestText)}"#)
            #expect(ranged.documents.count >= 1)
            #expect(ranged.documents.count <= 6)
            #expect(ranged.meta.total == ranged.documents.count)

            let future = try await Self.executeJobs(
                adapter, #"{"queue":"it-emails","state":"completed","from":\#(Self.number(Self.base + 10_000_000))}"#)
            #expect(future.documents.isEmpty)
            #expect(future.meta.total == 0)
            #expect(!future.meta.truncated)
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func appliesNameGlobAndWhereDotPathFiltersAgainstLiveHashes() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let byName = try await Self.executeJobs(
                adapter, #"{"queue":"it-emails","state":"completed","name":"welcome-*"}"#)
            #expect(byName.documents.count == 4)
            #expect(byName.meta.scanned == 6)
            #expect(!byName.meta.truncated)

            let byPath = try await Self.executeJobs(
                adapter, #"{"queue":"it-emails","state":"completed","where":{"user.id":2}}"#)
            #expect(byPath.documents.count == 1)
            #expect(Self.stringField(try #require(byPath.documents.first), "name") == "welcome-email")
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func truncatesAtScanBudgetAndResumesToTheEndWithoutGapsOrRepeats() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            var seen = Set<String>()
            var scannedTotal = 0
            var cursor: Int?
            while true {
                var query = #"{"queue":"it-emails","state":"failed","name":"welcome-*","scanBudget":2"#
                if let cursor { query += #","cursor":\#(cursor)"# }
                query += "}"
                let page = try await Self.executeJobs(adapter, query)
                scannedTotal += page.meta.scanned ?? 0
                for document in page.documents {
                    let id = try #require(Self.stringField(document, "id"))
                    #expect(!seen.contains(id))
                    seen.insert(id)
                }
                if !page.meta.truncated {
                    #expect(page.meta.nextCursor == 4)
                    break
                }
                cursor = page.meta.nextCursor
                #expect((cursor ?? 0) > 0)
            }
            // Two of the four failed jobs are welcome-email; every index entry scanned.
            #expect(seen.count == 2)
            #expect(scannedTotal == 4)
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func pagesUnfilteredStateIndexToCompletionWithoutGapsOrRepeats() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            var seen = Set<String>()
            var cursor: Int?
            while true {
                var query = #"{"queue":"it-emails","state":"completed","limit":2"#
                if let cursor { query += #","cursor":\#(cursor)"# }
                query += "}"
                let page = try await Self.executeJobs(adapter, query)
                for document in page.documents {
                    let id = try #require(Self.stringField(document, "id"))
                    #expect(!seen.contains(id))
                    seen.insert(id)
                }
                if !page.meta.truncated { break }
                cursor = page.meta.nextCursor
            }
            #expect(seen.count == 6)
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func honoursCancellationRegisteredBeforeExecution() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let requestID = UUID()
            try await adapter.cancel(requestID: requestID)
            await #expect(throws: BullmqAdapterError.cancelled) {
                _ = try await Self.executeJobs(
                    adapter, #"{"queue":"it-emails","state":"failed"}"#, requestID: requestID)
            }
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func readsJobsParkedInThePausedList() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let result = try await Self.executeJobs(adapter, #"{"queue":"it-paused","state":"paused"}"#)
            #expect(result.documents.count == 2)
            #expect(result.meta.total == 2)
            #expect(!result.meta.truncated)
            for document in result.documents {
                #expect(Self.stringField(document, "queue") == Self.pausedQueue)
                #expect(Self.stringField(document, "state") == "paused")
                #expect(Self.stringField(document, "name") == "paused-task")
            }
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func readsWaitingChildrenParentsAndFiltersByTimestampScores() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let all = try await Self.executeJobs(adapter, #"{"queue":"it-flow","state":"waiting-children"}"#)
            #expect(all.documents.count == 1)
            let document = try #require(all.documents.first)
            #expect(Self.stringField(document, "queue") == Self.flowQueue)
            #expect(Self.stringField(document, "state") == "waiting-children")
            #expect(Self.stringField(document, "name") == "parent-report")

            let future = try await Self.executeJobs(
                adapter,
                #"{"queue":"it-flow","state":"waiting-children","from":\#(Self.number(Self.base + 10_000_000))}"#)
            #expect(future.documents.isEmpty)
            #expect(future.meta.total == 0)
            #expect(!future.meta.truncated)
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func returnsJobLogsWithIncludeLogsAndOmitsThemOtherwise() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let withLogs = try await Self.executeJobs(
                adapter, #"{"queue":"it-emails","state":"completed","name":"invoice-email","includeLogs":true}"#)
            #expect(withLogs.documents.count == 2)
            for document in withLogs.documents {
                #expect(Self.field(document, "logs") == .array([.string("rendering invoice"), .string("sent through smtp")]))
                #expect(Self.numberField(document, "logsTotal") == 2)
            }

            let withoutLogs = try await Self.executeJobs(
                adapter, #"{"queue":"it-emails","state":"completed","name":"invoice-email"}"#)
            #expect(withoutLogs.documents.count == 2)
            for document in withoutLogs.documents {
                #expect(Self.field(document, "logs") == nil)
                #expect(Self.field(document, "logsTotal") == nil)
            }
        }
    }

    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func appliesFromToInMemoryForPrioritizedJobsWithPackedScores() async throws {
        try await Self.run(seed: Self.seedAll) { adapter in
            let all = try await Self.executeJobs(adapter, #"{"queue":"it-emails","state":"prioritized"}"#)
            // Raw ascending-score order: with packed scores the lower-priority
            // job (priority 2) sorts before the priority-5 one.
            #expect(all.documents.count == 2)
            #expect(all.meta.total == 2)
            #expect(!all.meta.truncated)
            let userIDs = all.documents.compactMap { document -> Double? in
                guard case .object(let pairs)? = Self.field(document, "data"),
                      let id = pairs.first(where: { $0.key == "userId" })?.value,
                      case .number(let number) = id else { return nil }
                return number
            }
            #expect(userIDs == [402, 401])

            let latest = try #require(all.documents.compactMap { Self.numberField($0, "timestamp") }.max())
            let ranged = try await Self.executeJobs(
                adapter,
                #"{"queue":"it-emails","state":"prioritized","from":\#(Self.number(latest))}"#)
            #expect(ranged.documents.count == 1)
            let document = try #require(ranged.documents.first)
            #expect(Self.stringField(document, "name") == "urgent-email")
            // The packed zset scores must not leak into the range: the total
            // stays the whole index.
            #expect(ranged.meta.total == 2)
            #expect(!ranged.meta.truncated)
        }
    }

    /// The default (Lua) fetcher — used by every other test here — and the JS
    /// fetcher must agree page for page.
    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func matchesLuaAndJsFetchersPageForPage() async throws {
        let jsClient = try Self.makeClient()
        try await jsClient.connect()
        let jsAdapter = try Self.makeAdapter(client: jsClient, fetcher: BullmqJsPageFetcher(client: jsClient))
        try await Self.run(seed: Self.seedAll) { luaAdapter in
            try await jsAdapter.connect()
            let queries = [
                #"{"queue":"it-emails","state":"failed"}"#,
                #"{"queue":"it-emails","state":"completed","name":"welcome-*"}"#,
                #"{"queue":"it-emails","state":"completed","limit":2}"#,
                #"{"queue":"it-emails","state":"waiting"}"#,
                #"{"queue":"it-emails","state":"prioritized","from":\#(Self.number(Self.base + 82_000))}"#,
                #"{"queue":"it-emails","state":"completed","name":"invoice-email","includeLogs":true}"#,
                #"{"queue":"it-paused","state":"paused"}"#,
                #"{"queue":"it-flow","state":"waiting-children"}"#,
            ]
            for query in queries {
                let viaLua = try await Self.executeJobs(luaAdapter, query)
                let viaJs = try await Self.executeJobs(jsAdapter, query)
                #expect(viaJs.documents == viaLua.documents, "documents diverge for \(query)")
                #expect(viaJs.meta.scanned == viaLua.meta.scanned, "scanned diverges for \(query)")
                #expect(viaJs.meta.total == viaLua.meta.total, "total diverges for \(query)")
                #expect(viaJs.meta.nextCursor == viaLua.meta.nextCursor, "nextCursor diverges for \(query)")
                #expect(viaJs.meta.truncated == viaLua.meta.truncated, "truncated diverges for \(query)")
            }
            await jsAdapter.close()
        }
    }
}

import GRDB

extension BullmqAdapterIntegrationTests {
    /// Snapshot end-to-end: collect the seeded queue through the real adapter
    /// (Lua fetcher) into a GRDB-written SQLite file, then assert with SQL.
    @Test(.enabled(if: BullmqAdapterIntegrationTests.redisURL != nil))
    func syncsQueueIntoQueryableSnapshotSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbbbb-bullmq-snapshot-it-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try await Self.run(seed: Self.seedAll) { adapter in
            guard let collector = adapter as? any SupportsBullmqSnapshot else {
                Issue.record("the adapter must conform to SupportsBullmqSnapshot")
                return
            }
            let file = directory.appendingPathComponent("snapshot.sqlite")
            let writer = try BullmqSnapshotWriter(fileURL: file)
            let batches = BatchCollector()
            let collected = try await collector.collectBullmqJobs(
                options: BullmqCollectOptions(queue: Self.queue, requestID: UUID())) { jobs in
                try writer.insertBatch(jobs)
                batches.append(jobs)
            }
            try writer.commit()

            // completed 6 + failed 4 + waiting 2 + delayed 2 + prioritized 2
            #expect(collected == 16)
            #expect(batches.batches.allSatisfy { $0.count <= 500 })

            let database = try DatabaseQueue(path: file.path)
            try await database.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT count(*) FROM jobs")
                #expect(total == 16)

                let byState = try Row.fetchAll(
                    db, sql: "SELECT state, count(*) AS c FROM jobs GROUP BY state ORDER BY state")
                    .map { (state: $0["state"] as String, count: $0["c"] as Int) }
                #expect(byState.map(\.state) == ["completed", "delayed", "failed", "prioritized", "waiting"])
                #expect(byState.map(\.count) == [6, 2, 4, 2, 2])

                // Payloads are raw JSON: json_extract works over them.
                let pro = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM jobs WHERE json_extract(data, '$.user.tier') = 'pro'")
                #expect((pro ?? 0) > 0)

                let stacktrace = try String.fetchOne(
                    db, sql: "SELECT stacktrace FROM jobs WHERE state = 'failed' LIMIT 1")
                #expect(stacktrace?.contains("SMTP rejected recipient") == true)

                let indexes = try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
                #expect(indexes == ["idx_jobs_finished_on", "idx_jobs_name", "idx_jobs_state"])
            }
        }
    }
}
