import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit

/// Port of the Electron reference's `bullmq-adapter.test.ts` — one Swift
/// Testing case per vitest case, over the injected fake client + JS fetcher.
struct BullmqAdapterTests {
    typealias F = BullmqTestFixtures

    // MARK: Connection handling

    @Test func rejectsInvalidConnectionInput() {
        #expect(throws: BullmqAdapterError.invalidConfiguration) {
            _ = try BullmqAdapter(input: F.makeInput { $0.port = 0 }, client: FakeRedis(), fetcher: nil)
        }
        #expect(throws: BullmqAdapterError.invalidConfiguration) {
            _ = try BullmqAdapter(input: F.makeInput { $0.database = 16 }, client: FakeRedis(), fetcher: nil)
        }
        #expect(throws: BullmqAdapterError.invalidConfiguration) {
            _ = try BullmqAdapter(input: F.makeInput { $0.prefix = "bad*prefix" }, client: FakeRedis(), fetcher: nil)
        }
        #expect(throws: BullmqAdapterError.invalidConfiguration) {
            _ = try BullmqAdapter(input: F.makeInput { $0.host = "  " }, client: FakeRedis(), fetcher: nil)
        }
    }

    @Test func reportsUnreachableAndAuthFailuresAsFriendlyErrors() async throws {
        let refused = FakeRedis()
        refused.failConnect = F.FakeFailure(message: "connect ECONNREFUSED 127.0.0.1:6379")
        let refusedAdapter = try F.makeAdapter(refused)
        await #expect(throws: BullmqAdapterError.redis(.unreachable)) {
            try await refusedAdapter.connect()
        }
        #expect(refused.disconnected)

        let denied = FakeRedis()
        denied.failConnect = F.FakeFailure(message: "NOAUTH Authentication required.")
        let deniedAdapter = try F.makeAdapter(denied)
        await #expect(throws: BullmqAdapterError.redis(.authenticationFailed)) {
            try await deniedAdapter.connect()
        }
    }

    @Test func refusesWorkAfterClose() async throws {
        let fake = FakeRedis()
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()
        await adapter.close()
        #expect(fake.disconnected)
        await adapter.close()
        await #expect(throws: BullmqAdapterError.closed) {
            _ = try await adapter.listObjects()
        }
    }

    @Test func rejectsMismatchedCommands() async throws {
        let adapter = try F.makeAdapter(FakeRedis())
        await #expect(throws: BullmqAdapterError.commandRejected) {
            _ = try await adapter.execute(.mongoFind(collection: "c", filter: "{}"), options: F.makeOptions())
        }
        await adapter.close()
    }

    // MARK: Object introspection

    @Test func discoversQueuesThroughPagedScanAndReportsPerStateCounts() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100), F.failedJob("2", 200), F.failedJob("3", 300),
            .init(id: "9", state: .waiting, score: 0, hash: ["name": "digest"]),
            .init(id: "10", state: .waiting, score: 0, hash: ["name": "digest"]),
        ])
        fake.seedQueue("ops:reports", jobs: [F.failedJob("7", 50)])
        fake.seedQueue("alpha", jobs: [])
        fake.seedQueue("beta", jobs: [])

        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()
        let nodes = try await adapter.listObjects()

        let queues = nodes.filter { $0.kind == .collection }
        #expect(queues.map(\.id) == ["alpha", "beta", "emails", "ops:reports"])

        let emailsStates = nodes.filter { $0.parentID == "emails" }
        #expect(emailsStates.count == 8)
        #expect(emailsStates.map(\.name) == BullmqJobState.allCases.map(\.rawValue))
        #expect(emailsStates.allSatisfy { $0.kind == .table })
        #expect(emailsStates.first { $0.id == "emails:failed" }?.detail == "3 jobs")
        #expect(emailsStates.first { $0.id == "emails:waiting" }?.detail == "2 jobs")
        #expect(emailsStates.first { $0.id == "emails:active" }?.detail == "0 jobs")
        #expect(emailsStates.first { $0.id == "emails:paused" }?.detail == "0 jobs")
        #expect(emailsStates.first { $0.id == "emails:waiting-children" }?.detail == "0 jobs")
        #expect(nodes.first { $0.id == "ops:reports:failed" }?.detail == "1 job")
        await adapter.close()
    }

    @Test func previewsQueueAndStateNodesColonNamesIncluded() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [F.failedJob("1", 100)])
        fake.seedQueue("ops:reports", jobs: [F.failedJob("7", 50)])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()
        let nodes = try await adapter.listObjects()

        // Queue node → failed-state preview of the whole queue.
        let queueNode = try #require(nodes.first { $0.id == "emails" })
        let queuePreview = try await adapter.previewObject(PreviewRequest(object: queueNode))
        guard case .documents(let queueDocs, _) = queuePreview else {
            Issue.record("queue preview must return documents")
            return
        }
        #expect(F.ids(queueDocs) == ["1"])
        #expect(queueDocs.allSatisfy { F.stringField($0, "state") == "failed" })

        // State node → that state's page.
        let delayedNode = DatabaseObject(id: "emails:delayed", parentID: "emails", name: "delayed", kind: .table)
        let delayedPreview = try await adapter.previewObject(PreviewRequest(object: delayedNode))
        guard case .documents(let delayedDocs, _) = delayedPreview else {
            Issue.record("state preview must return documents")
            return
        }
        #expect(delayedDocs.isEmpty)

        // A queue whose name contains a colon stays a queue node.
        let colonNode = try #require(nodes.first { $0.id == "ops:reports" })
        let colonPreview = try await adapter.previewObject(PreviewRequest(object: colonNode))
        guard case .documents(let colonDocs, _) = colonPreview else {
            Issue.record("colon queue preview must return documents")
            return
        }
        #expect(F.ids(colonDocs) == ["7"])

        let colonStateNode = DatabaseObject(id: "ops:reports:failed", parentID: "ops:reports", name: "failed", kind: .table)
        let colonStatePreview = try await adapter.previewObject(PreviewRequest(object: colonStateNode))
        guard case .documents(let colonStateDocs, _) = colonStatePreview else {
            Issue.record("colon state preview must return documents")
            return
        }
        #expect(F.ids(colonStateDocs) == ["7"])

        await #expect(throws: BullmqAdapterError.unknownObject) {
            _ = try await adapter.previewObject(PreviewRequest(
                object: DatabaseObject(id: "unknown", parentID: nil, name: "unknown", kind: .collection)))
        }
        await adapter.close()
    }

    // MARK: Execute

    @Test func pagesStateIndexWithoutFiltersAndReportsCursors() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100), F.failedJob("2", 200), F.failedJob("3", 300),
            F.failedJob("4", 400), F.failedJob("5", 500),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let first = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed","limit":2}"#)
        #expect(F.ids(first.documents) == ["1", "2"])
        #expect(first.meta.count == 2)
        #expect(first.meta.truncated)
        #expect(first.meta.scanned == 2)
        #expect(first.meta.total == 5)
        #expect(first.meta.nextCursor == 2)

        let resumed = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","limit":2,"cursor":\#(first.meta.nextCursor ?? -1)}"#)
        #expect(F.ids(resumed.documents) == ["3", "4"])
        #expect(resumed.meta.truncated)
        #expect(resumed.meta.nextCursor == 4)

        let last = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","limit":2,"cursor":\#(resumed.meta.nextCursor ?? -1)}"#)
        #expect(F.ids(last.documents) == ["5"])
        #expect(!last.meta.truncated)
        #expect(last.meta.total == 5)
        #expect(last.meta.nextCursor == 5)
        await adapter.close()
    }

    @Test func appliesTimeRangesToZsetStatesAndIgnoresThemForListStates() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100), F.failedJob("2", 200), F.failedJob("3", 300),
            .init(id: "9", state: .waiting, score: 0, hash: ["name": "digest"]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let ranged = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed","from":150,"to":300}"#)
        #expect(F.ids(ranged.documents) == ["2", "3"])
        #expect(ranged.meta.total == 2)
        #expect(!ranged.meta.truncated)

        let waiting = try await F.executeJobs(adapter, #"{"queue":"emails","state":"waiting","from":1000000}"#)
        #expect(F.ids(waiting.documents) == ["9"])
        #expect(waiting.meta.total == 1)
        await adapter.close()
    }

    @Test func filtersByNameGlobAndWhereDotPaths() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100, hash: ["name": "welcome-email", "data": #"{"user":{"id":1}}"#]),
            F.failedJob("2", 200, hash: ["name": "invoice-email", "data": #"{"user":{"id":2}}"#]),
            F.failedJob("3", 300, hash: ["name": "welcome-sms", "data": #"{"user":{"id":3}}"#]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let byName = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed","name":"welcome-*"}"#)
        #expect(F.ids(byName.documents) == ["1", "3"])
        #expect(byName.meta.scanned == 3)
        #expect(!byName.meta.truncated)

        let byPath = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","where":{"user.id":2}}"#)
        #expect(F.ids(byPath.documents) == ["2"])

        let combined = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","name":"*-email","where":{"user.id":1}}"#)
        #expect(F.ids(combined.documents) == ["1"])
        await adapter.close()
    }

    @Test func stopsFilteredScansAtScanBudgetAndResumesFromNextCursor() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100, hash: ["name": "digest"]),
            F.failedJob("2", 200, hash: ["name": "digest"]),
            F.failedJob("3", 300, hash: ["name": "digest"]),
            F.failedJob("4", 400, hash: ["name": "wanted"]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let truncated = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","name":"wanted","scanBudget":2}"#)
        #expect(truncated.documents.isEmpty)
        #expect(truncated.meta.scanned == 2)
        #expect(truncated.meta.truncated)
        #expect(truncated.meta.total == 4)
        #expect(truncated.meta.nextCursor == 2)

        let resumed = try await F.executeJobs(
            adapter,
            #"{"queue":"emails","state":"failed","name":"wanted","scanBudget":5,"cursor":\#(truncated.meta.nextCursor ?? -1)}"#)
        #expect(F.ids(resumed.documents) == ["4"])
        #expect(!resumed.meta.truncated)
        #expect(resumed.meta.nextCursor == 4)
        await adapter.close()
    }

    @Test func stopsFilteredScansOnceTheLimitIsFilled() async throws {
        let fake = FakeRedis()
        var jobs: [FakeRedis.FakeJob] = [
            F.failedJob("match-1", 1, hash: ["name": "wanted"]),
            F.failedJob("match-2", 2, hash: ["name": "wanted"]),
        ]
        for index in 0..<250 {
            jobs.append(F.failedJob("rest-\(index)", 100 + Double(index), hash: ["name": "digest"]))
        }
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()
        fake.seedQueue("emails", jobs: jobs)

        let result = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","name":"wanted","limit":1}"#)
        #expect(F.ids(result.documents) == ["match-1"])
        // The batch covering the match was consumed, so the cursor lands past it.
        #expect(result.meta.truncated)
        #expect(result.meta.nextCursor == 200)
        #expect(result.meta.total == 252)
        await adapter.close()
    }

    @Test func honoursCancellationRegisteredBeforeOrDuringAScan() async throws {
        let fake = FakeRedis()
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let early = F.makeOptions()
        try await adapter.cancel(requestID: early.requestID)
        await #expect(throws: BullmqAdapterError.cancelled) {
            _ = try await adapter.execute(
                .bullmqJobs(#"{"queue":"emails","state":"failed"}"#), options: early)
        }

        var jobs: [FakeRedis.FakeJob] = []
        for index in 0..<300 {
            jobs.append(.init(id: String(index), state: .waiting, score: 0, hash: ["name": "digest"]))
        }
        fake.seedQueue("emails", jobs: jobs)
        let mid = F.makeOptions()
        let requestID = mid.requestID
        fake.pipelineHook = { [adapter] in try await adapter.cancel(requestID: requestID) }
        await #expect(throws: BullmqAdapterError.cancelled) {
            _ = try await adapter.execute(
                .bullmqJobs(#"{"queue":"emails","state":"waiting","name":"dig*","limit":500}"#),
                options: mid)
        }
        await adapter.close()
    }

    @Test func capsTheRequestedLimitByTheExecutionRowBudget() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [F.failedJob("1", 100), F.failedJob("2", 200), F.failedJob("3", 300)])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let result = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","limit":100}"#,
            options: F.makeOptions { $0 = ExecuteOptions(requestID: $0.requestID, timeout: $0.timeout, maxRows: 2, maxBytes: $0.maxBytes) })
        #expect(result.documents.count == 2)
        #expect(result.meta.truncated)
        await adapter.close()
    }

    @Test func appliesTheByteBudgetToDocuments() async throws {
        let fake = FakeRedis()
        let blob = String(repeating: "x", count: 1024)
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100, hash: ["data": #"{"blob":"\#(blob)"}"#]),
            F.failedJob("2", 200, hash: ["data": #"{"blob":"\#(blob)"}"#]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let result = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed"}"#,
            options: F.makeOptions { $0 = ExecuteOptions(requestID: $0.requestID, timeout: $0.timeout, maxRows: $0.maxRows, maxBytes: 1300) })
        #expect(result.documents.count == 1)
        #expect(result.meta.truncated)
        await adapter.close()
    }

    // MARK: Query parsing and hash conversion

    @Test func rejectsMalformedQueryJSONWithFriendlyErrors() async throws {
        let adapter = try F.makeAdapter(FakeRedis())

        await #expect(throws: BullmqAdapterError.invalidQuery("Invalid BullMQ query JSON. Check quotes, commas, and braces.")) {
            _ = try await adapter.execute(.bullmqJobs("{ nope"), options: F.makeOptions())
        }
        await #expect(throws: BullmqAdapterError.invalidQuery("A BullMQ job query must be one JSON object.")) {
            _ = try await adapter.execute(.bullmqJobs("[]"), options: F.makeOptions())
        }
        await #expect(throws: BullmqAdapterError.invalidQuery("BullMQ job query queue is invalid.")) {
            _ = try await adapter.execute(.bullmqJobs(#"{"state":"failed"}"#), options: F.makeOptions())
        }
        await #expect {
            _ = try await adapter.execute(.bullmqJobs(#"{"queue":"emails","state":"stalled"}"#), options: F.makeOptions())
        } throws: { error in
            guard case BullmqAdapterError.invalidQuery(let message) = error else { return false }
            return message.hasPrefix("BullMQ job query state must be one of:")
        }
        await #expect(throws: BullmqAdapterError.invalidQuery("BullMQ job query from must not be after to.")) {
            _ = try await adapter.execute(
                .bullmqJobs(#"{"queue":"emails","state":"failed","from":300,"to":100}"#), options: F.makeOptions())
        }
        await #expect(throws: BullmqAdapterError.invalidQuery("BullMQ job query limit is invalid.")) {
            _ = try await adapter.execute(
                .bullmqJobs(#"{"queue":"emails","state":"failed","limit":0}"#), options: F.makeOptions())
        }
        await #expect(throws: BullmqAdapterError.invalidQuery("BullMQ job query cursor is invalid.")) {
            _ = try await adapter.execute(
                .bullmqJobs(#"{"queue":"emails","state":"failed","cursor":-1}"#), options: F.makeOptions())
        }
        await adapter.close()
    }

    @Test func appliesDefaultsAndCapsToOptionalQueryFields() throws {
        let defaults = try BullmqQueryParser.parse(#"{"queue":"q","state":"failed"}"#)
        #expect(defaults.limit == 100)
        #expect(defaults.scanBudget == 5000)
        #expect(defaults.cursor == 0)
        let capped = try BullmqQueryParser.parse(#"{"queue":"q","state":"failed","limit":9999,"scanBudget":999999}"#)
        #expect(capped.limit == 500)
        #expect(capped.scanBudget == 50000)
    }

    @Test func convertsJobHashesIntoDocumentsWithParsedPayloadsAndNumericFields() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            .init(id: "1", state: .failed, score: 100, hash: [
                "name": "welcome-email",
                "data": #"{"userId":1}"#,
                "opts": #"{"attempts":3,"backoff":{"type":"fixed","delay":1000}}"#,
                // BullMQ ≥5 stores attemptsMade under the short `atm` key.
                "atm": "2",
                "failedReason": "SMTP timeout",
                "stacktrace": #"["Error: SMTP timeout","    at send (mail.js:1)"]"#,
                "timestamp": "1756490000000",
                "processedOn": "1756490001000",
                "finishedOn": "1756490002000",
                "delay": "5000",
            ]),
            .init(id: "2", state: .failed, score: 200, hash: [
                "name": "plain-failure",
                "stacktrace": "Error: plain\n    at worker (job.js:2)",
            ]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let result = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed"}"#)
        let first = try #require(result.documents.first)
        #expect(F.stringField(first, "id") == "1")
        #expect(F.stringField(first, "queue") == "emails")
        #expect(F.stringField(first, "state") == "failed")
        #expect(F.stringField(first, "name") == "welcome-email")
        #expect(F.field(first, "data") == BullmqJSON.parse(#"{"userId":1}"#))
        #expect(F.field(first, "opts") == BullmqJSON.parse(#"{"attempts":3,"backoff":{"type":"fixed","delay":1000}}"#))
        #expect(F.numberField(first, "attemptsMade") == 2)
        #expect(F.stringField(first, "failedReason") == "SMTP timeout")
        #expect(F.field(first, "stacktrace") == .array([.string("Error: SMTP timeout"), .string("    at send (mail.js:1)")]))
        #expect(F.numberField(first, "timestamp") == 1_756_490_000_000)
        #expect(F.numberField(first, "processedOn") == 1_756_490_001_000)
        #expect(F.numberField(first, "finishedOn") == 1_756_490_002_000)
        #expect(F.numberField(first, "delay") == 5000)

        // A raw multi-line stacktrace splits into lines; absent fields are omitted.
        let second = try #require(result.documents.dropFirst().first)
        #expect(F.stringField(second, "id") == "2")
        #expect(F.field(second, "stacktrace") == .array([.string("Error: plain"), .string("    at worker (job.js:2)")]))
        #expect(F.field(second, "data") == nil)
        #expect(F.field(second, "opts") == nil)
        #expect(F.field(second, "failedReason") == nil)
        #expect(F.field(second, "attemptsMade") == nil)
        await adapter.close()
    }

    @Test func skipsJobsWhoseHashVanishedAfterTheIndexRead() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [F.failedJob("1", 100), F.failedJob("2", 200)])
        fake.removeHash("bull:emails:2")
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let result = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed"}"#)
        #expect(F.ids(result.documents) == ["1"])
        #expect(result.meta.total == 2)
        #expect(result.meta.count == 1)
        await adapter.close()
    }

    // MARK: collectBullmqJobs

    @Test func collectStreamsEveryStateInBatchesAndReturnsTheCount() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100),
            F.failedJob("2", 200),
            .init(id: "9", state: .waiting, score: 0, hash: ["name": "digest"]),
            .init(id: "10", state: .active, score: 0, hash: ["name": "invoice", "attemptsMade": "1"]),
            .init(id: "11", state: .delayed, score: 999, hash: ["name": "reminder", "delay": "5000"]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let batches = BatchCollector()
        let collected = try await adapter.collectBullmqJobs(
            options: BullmqCollectOptions(queue: "emails")) { jobs in
            batches.append(jobs)
        }

        #expect(collected == 5)
        let jobs = batches.flattened
        #expect(F.ids(jobs).sorted() == ["1", "10", "11", "2", "9"])
        let active = jobs.first { F.stringField($0, "id") == "10" }
        #expect(F.stringField(try #require(active), "queue") == "emails")
        #expect(F.stringField(try #require(active), "state") == "active")
        #expect(F.numberField(try #require(active), "attemptsMade") == 1)
        await adapter.close()
    }

    @Test func collectHonoursStatesFilterAndSkipsVanishedHashes() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100),
            F.failedJob("2", 200),
            .init(id: "9", state: .waiting, score: 0, hash: ["name": "digest"]),
        ])
        fake.removeHash("bull:emails:2")
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let batches = BatchCollector()
        let collected = try await adapter.collectBullmqJobs(
            options: BullmqCollectOptions(queue: "emails", states: [.failed])) { batch in
            batches.append(batch)
        }

        #expect(collected == 1)
        #expect(F.ids(batches.flattened) == ["1"])
        await adapter.close()
    }

    @Test func collectFindsNothingForUnknownQueueWithoutCallingTheCallback() async throws {
        let adapter = try F.makeAdapter(FakeRedis())
        try await adapter.connect()
        let batches = BatchCollector()
        let collected = try await adapter.collectBullmqJobs(
            options: BullmqCollectOptions(queue: "missing")) { batch in batches.append(batch) }
        #expect(collected == 0)
        #expect(batches.count == 0)
        await adapter.close()
    }

    @Test func collectRejectsInvalidQueueNames() async throws {
        let adapter = try F.makeAdapter(FakeRedis())
        try await adapter.connect()
        await #expect(throws: BullmqAdapterError.invalidQuery("BullMQ snapshot queue is invalid.")) {
            _ = try await adapter.collectBullmqJobs(options: BullmqCollectOptions(queue: "  ")) { _ in }
        }
        await adapter.close()
    }

    @Test func collectStopsCooperativelyWhenCancelledBeforeOrDuring() async throws {
        let fake = FakeRedis()
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let early = UUID()
        try await adapter.cancel(requestID: early)
        await #expect(throws: BullmqAdapterError.cancelled) {
            _ = try await adapter.collectBullmqJobs(
                options: BullmqCollectOptions(queue: "emails", requestID: early)) { _ in }
        }

        var jobs: [FakeRedis.FakeJob] = []
        for index in 0..<1200 {
            jobs.append(.init(id: String(index), state: .waiting, score: 0, hash: ["name": "digest"]))
        }
        fake.seedQueue("emails", jobs: jobs)
        let batches = BatchCollector()
        let mid = UUID()
        fake.pipelineHook = { [adapter] in try await adapter.cancel(requestID: mid) }
        await #expect(throws: BullmqAdapterError.cancelled) {
            _ = try await adapter.collectBullmqJobs(
                options: BullmqCollectOptions(queue: "emails", states: [.waiting], requestID: mid)) { batch in
                batches.append(batch)
            }
        }
        #expect(batches.count == 1)
        await adapter.close()
    }

    // MARK: Paused and waiting-children states

    @Test func readsPausedListAndWaitingChildrenZsetLikeAnyOtherState() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            .init(id: "p1", state: .paused, score: 0, hash: ["name": "digest", "timestamp": "1756490000000"]),
            .init(id: "p2", state: .paused, score: 0, hash: ["name": "digest", "timestamp": "1756490001000"]),
            .init(id: "w1", state: .waitingChildren, score: 1_756_490_100_000,
                  hash: ["name": "parent-report", "timestamp": "1756490100000"]),
            .init(id: "w2", state: .waitingChildren, score: 1_756_490_200_000,
                  hash: ["name": "parent-report", "timestamp": "1756490200000"]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let paused = try await F.executeJobs(adapter, #"{"queue":"emails","state":"paused"}"#)
        #expect(F.ids(paused.documents) == ["p1", "p2"])
        #expect(paused.meta.total == 2)
        #expect(!paused.meta.truncated)

        let waitingChildren = try await F.executeJobs(
            adapter,
            #"{"queue":"emails","state":"waiting-children","from":1756490050000,"to":1756490150000}"#)
        // waiting-children scores are plain timestamps, so the range stays
        // server-side (ZRANGEBYSCORE).
        #expect(F.ids(waitingChildren.documents) == ["w1"])
        #expect(waitingChildren.meta.total == 1)
        #expect(!waitingChildren.meta.truncated)
        await adapter.close()
    }

    // MARK: Prioritized time ranges

    @Test func matchesFromToInMemoryAgainstJobTimestampsIgnoringPackedScores() async throws {
        let fake = FakeRedis()
        // Real prioritized scores pack priority into the high bits, so a score
        // window would be meaningless; the filter must read the hash.
        let packed = { (priority: Double, timestamp: Double) in priority * 1e15 + timestamp }
        fake.seedQueue("emails", jobs: [
            .init(id: "hi", state: .prioritized, score: packed(5, 1_756_490_000_000),
                  hash: ["name": "urgent", "timestamp": "1756490000000"]),
            .init(id: "mid", state: .prioritized, score: packed(2, 1_756_490_100_000),
                  hash: ["name": "urgent", "timestamp": "1756490100000"]),
            .init(id: "lo", state: .prioritized, score: packed(1, 1_756_490_200_000),
                  hash: ["name": "urgent", "timestamp": "1756490200000"]),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let all = try await F.executeJobs(adapter, #"{"queue":"emails","state":"prioritized"}"#)
        #expect(all.documents.count == 3)
        #expect(all.meta.total == 3)
        #expect(!all.meta.truncated)

        let ranged = try await F.executeJobs(
            adapter,
            #"{"queue":"emails","state":"prioritized","from":1756490050000,"to":1756490150000}"#)
        #expect(F.ids(ranged.documents) == ["mid"])
        // total stays the full index size: the range is applied in memory.
        #expect(ranged.meta.total == 3)
        #expect(ranged.meta.scanned == 3)
        #expect(!ranged.meta.truncated)

        let open = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"prioritized","from":1756490150000}"#)
        #expect(F.ids(open.documents) == ["lo"])
        await adapter.close()
    }

    // MARK: Job logs

    @Test func attachesBoundedLogTailAndTotalOnlyWhenIncludeLogsIsSet() async throws {
        let fake = FakeRedis()
        fake.seedQueue("emails", jobs: [
            F.failedJob("1", 100),
            .init(id: "2", state: .failed, score: 200,
                  hash: ["name": "invoice-email", "failedReason": "boom", "timestamp": "1756490000000"],
                  logs: ["picked up", "smtp handshake", "boom"]),
            .init(id: "3", state: .failed, score: 300,
                  hash: ["name": "digest", "timestamp": "1756490001000"],
                  logs: (1...150).map { "line \($0)" }),
        ])
        let adapter = try F.makeAdapter(fake)
        try await adapter.connect()

        let withLogs = try await F.executeJobs(
            adapter, #"{"queue":"emails","state":"failed","includeLogs":true}"#)
        let first = try #require(withLogs.documents.first)
        #expect(F.field(first, "logs") == .array([]))
        #expect(F.numberField(first, "logsTotal") == 0)
        let second = withLogs.documents[1]
        #expect(F.field(second, "logs") == .array([.string("picked up"), .string("smtp handshake"), .string("boom")]))
        #expect(F.numberField(second, "logsTotal") == 3)
        let tailed = withLogs.documents[2]
        #expect(F.numberField(tailed, "logsTotal") == 150)
        guard case .array(let tail)? = F.field(tailed, "logs") else {
            Issue.record("logs must be an array")
            return
        }
        #expect(tail.count == 100)
        #expect(tail.first == .string("line 51"))

        let withoutLogs = try await F.executeJobs(adapter, #"{"queue":"emails","state":"failed"}"#)
        for document in withoutLogs.documents {
            #expect(F.field(document, "logs") == nil)
            #expect(F.field(document, "logsTotal") == nil)
        }

        // Snapshot collection stays lightweight and never pulls logs.
        let collected = BatchCollector()
        _ = try await adapter.collectBullmqJobs(
            options: BullmqCollectOptions(queue: "emails", states: [.failed])) { batch in
            collected.append(batch)
        }
        #expect(collected.flattened.count == 3)
        for job in collected.flattened {
            #expect(F.field(job, "logs") == nil)
        }
        await adapter.close()
    }

    @Test func rejectsANonBooleanIncludeLogs() throws {
        #expect(throws: BullmqAdapterError.invalidQuery("BullMQ job query includeLogs is invalid.")) {
            _ = try BullmqQueryParser.parse(#"{"queue":"q","state":"failed","includeLogs":"yes"}"#)
        }
        #expect(try BullmqQueryParser.parse(#"{"queue":"q","state":"failed","includeLogs":true}"#).includeLogs)
    }
}
