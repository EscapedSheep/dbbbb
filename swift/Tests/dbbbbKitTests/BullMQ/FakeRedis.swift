import Foundation
import Testing
import dbbbbCore
@testable import dbbbbKit

/// In-memory Redis fake mirroring the Electron reference's `FakeRedis`:
/// hashes/zsets/lists keyed by string, SCAN paging (3 keys per page), and a
/// pipeline supporting zcard/llen/hgetall/lrange. Unit tests always inject
/// the JS page fetcher; the Lua path is pinned by the integration suite.
final class FakeRedis: RedisClienting, @unchecked Sendable {
    struct FakeJob {
        var id: String
        var state: BullmqJobState
        var score: Double
        var hash: [String: String]
        var logs: [String]?
    }

    private(set) var hashes: [String: [String: String]] = [:]
    private var zsets: [String: [(member: String, score: Double)]] = [:]
    private var lists: [String: [String]] = [:]
    private var keys: Set<String> = []
    var failConnect: (any Error)?
    private(set) var disconnected = false
    /// Awaited inside `pipeline` — lets tests register a cancellation mid-scan.
    var pipelineHook: (@Sendable () async throws -> Void)?

    let prefix: String

    init(prefix: String = "bull") {
        self.prefix = prefix
    }

    func seedQueue(_ queue: String, jobs: [FakeJob]) {
        keys.insert("\(prefix):\(queue):id")
        for job in jobs {
            hashes["\(prefix):\(queue):\(job.id)"] = job.hash
            if let logs = job.logs { lists["\(prefix):\(queue):\(job.id):logs"] = logs }
            let indexKey = "\(prefix):\(queue):\(job.state.indexKey)"
            switch job.state {
            case .waiting, .active, .paused:
                lists[indexKey, default: []].append(job.id)
            default:
                var zset = zsets[indexKey] ?? []
                zset.append((job.id, job.score))
                zset.sort { $0.score < $1.score }
                zsets[indexKey] = zset
            }
        }
    }

    func removeHash(_ key: String) {
        hashes.removeValue(forKey: key)
    }

    func connect() async throws {
        if let failConnect { throw failConnect }
    }

    func ping() async throws {}

    func scan(cursor: String, match: String, count: Int) async throws -> (nextCursor: String, keys: [String]) {
        let all = keys.filter { BullmqGlobMatcher.matches(match, $0) }.sorted()
        let pageSize = 3
        let start = Int(cursor) ?? 0
        let page = Array(all[start...].prefix(pageSize))
        let next = start + pageSize >= all.count ? "0" : String(start + pageSize)
        return (next, page)
    }

    func zcard(_ key: String) async throws -> Int {
        zsets[key]?.count ?? 0
    }

    func zcount(_ key: String, min: String, max: String) async throws -> Int {
        let bounds = scoreBounds(min: min, max: max)
        return (zsets[key] ?? []).filter { $0.score >= bounds.lo && $0.score <= bounds.hi }.count
    }

    func llen(_ key: String) async throws -> Int {
        lists[key]?.count ?? 0
    }

    func zrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        let members = (zsets[key] ?? []).map(\.member)
        let range = Self.normalizeRange(length: members.count, start: start, stop: stop)
        return Array(members[range])
    }

    func lrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        let list = lists[key] ?? []
        let range = Self.normalizeRange(length: list.count, start: start, stop: stop)
        return Array(list[range])
    }

    func zrangebyscore(_ key: String, min: String, max: String, offset: Int, count: Int) async throws -> [String] {
        let bounds = scoreBounds(min: min, max: max)
        let matched = (zsets[key] ?? [])
            .filter { $0.score >= bounds.lo && $0.score <= bounds.hi }
            .map(\.member)
        return Array(matched.dropFirst(offset).prefix(count))
    }

    func hgetall(_ key: String) async throws -> [String: String] {
        hashes[key] ?? [:]
    }

    func pipeline(_ commands: [[String]]) async throws -> [RedisPipelineReply] {
        try await pipelineHook?()
        var replies: [RedisPipelineReply] = []
        for command in commands {
            guard let name = command.first else {
                replies.append(.error("empty command"))
                continue
            }
            switch name {
            case "zcard": replies.append(.value(.integer(Int64(try await zcard(command[1])))))
            case "llen": replies.append(.value(.integer(Int64(try await llen(command[1])))))
            case "hgetall":
                let hash = hashes[command[1]] ?? [:]
                var flat: [RedisValue] = []
                for (field, value) in hash.sorted(by: { $0.key < $1.key }) {
                    flat.append(.bulk(field))
                    flat.append(.bulk(value))
                }
                replies.append(.value(.array(flat)))
            case "lrange":
                let list = try await lrange(command[1], start: Int(command[2]) ?? 0, stop: Int(command[3]) ?? -1)
                replies.append(.value(.array(list.map { RedisValue.bulk($0) })))
            default:
                replies.append(.error("unsupported command \(name)"))
            }
        }
        return replies
    }

    func eval(_ script: String, keys: [String], arguments: [String]) async throws -> RedisValue {
        throw RedisError.server("FakeRedis cannot run Lua; inject the JS page fetcher.")
    }

    func disconnect() async {
        disconnected = true
    }

    private func scoreBounds(min: String, max: String) -> (lo: Double, hi: Double) {
        let lo = min == "-inf" ? -Double.infinity : (Double(min) ?? 0)
        let hi = max == "+inf" ? Double.infinity : (Double(max) ?? 0)
        return (lo, hi)
    }

    /// Redis-style inclusive range with negative-index normalization.
    static func normalizeRange(length: Int, start rawStart: Int, stop rawStop: Int) -> Range<Int> {
        let start = rawStart < 0 ? max(length + rawStart, 0) : rawStart
        let stop = rawStop < 0 ? length + rawStop : rawStop
        let clampedStop = min(stop, length - 1)
        guard start <= clampedStop, start < length else { return 0..<0 }
        return start..<(clampedStop + 1)
    }
}

enum BullmqTestFixtures {
    /// A plain (non-Redis) failure — the fake throws these so the adapter's
    /// message-based classification runs, exactly like the TS tests' `Error`.
    struct FakeFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    static func makeInput(_ overrides: (inout ConnectionInput.BullmqInput) -> Void = { _ in }) -> ConnectionInput.BullmqInput {
        var input = ConnectionInput.BullmqInput(
            name: "Queues", host: "localhost", port: 6379,
            database: 0, tls: false, prefix: "bull",
            environment: .development, readOnly: true)
        overrides(&input)
        return input
    }

    /// Unit tests run the injected JS fetcher; the default Lua path is covered
    /// by the real-Redis integration suite, which also pins parity between them.
    static func makeAdapter(
        _ fake: FakeRedis,
        overrides: (inout ConnectionInput.BullmqInput) -> Void = { _ in }
    ) throws -> BullmqAdapter {
        try BullmqAdapter(input: makeInput(overrides), client: fake, fetcher: BullmqJsPageFetcher(client: fake))
    }

    static func makeOptions(_ overrides: (inout ExecuteOptions) -> Void = { _ in }) -> ExecuteOptions {
        var options = ExecuteOptions(requestID: UUID(), timeout: .seconds(5), maxRows: 500, maxBytes: 5 * 1024 * 1024)
        overrides(&options)
        return options
    }

    static func executeJobs(
        _ adapter: BullmqAdapter,
        _ queryJSON: String,
        options: ExecuteOptions? = nil
    ) async throws -> (documents: [DisplayValue], meta: ResultMeta) {
        let result = try await adapter.execute(.bullmqJobs(queryJSON), options: options ?? makeOptions())
        guard case .documents(let documents, let meta) = result else {
            Issue.record("Expected a document result.")
            return ([], ResultMeta(count: 0, truncated: false, elapsedMilliseconds: 0))
        }
        return (documents, meta)
    }

    /// A failed-job hash in the shape BullMQ ≥5 writes (`attemptsMade` here is
    /// the long key; the `atm` short-key case has its own fixture).
    static func failedJob(_ id: String, _ score: Double, hash: [String: String] = [:]) -> FakeRedis.FakeJob {
        // Mirrors the TS fixture's `userId: Number(id)` — NaN becomes null.
        let userId = Double(id).map(BullmqJSON.numberString) ?? "null"
        var fields: [String: String] = [
            "name": "welcome-email",
            "data": #"{"userId":\#(userId)}"#,
            "opts": #"{"attempts":3}"#,
            "attemptsMade": "1",
            "timestamp": "1756490000000",
            "processedOn": "1756490001000",
            "finishedOn": BullmqJSON.numberString(score),
        ]
        for (key, value) in hash { fields[key] = value }
        return FakeRedis.FakeJob(id: id, state: .failed, score: score, hash: fields)
    }

    static func field(_ document: DisplayValue, _ key: String) -> DisplayValue? {
        guard case .object(let pairs) = document else { return nil }
        return pairs.first(where: { $0.key == key })?.value
    }

    static func stringField(_ document: DisplayValue, _ key: String) -> String? {
        guard case .string(let value)? = field(document, key) else { return nil }
        return value
    }

    static func numberField(_ document: DisplayValue, _ key: String) -> Double? {
        guard case .number(let value)? = field(document, key) else { return nil }
        return value
    }

    static func ids(_ documents: [DisplayValue]) -> [String] {
        documents.compactMap { stringField($0, "id") }
    }
}

/// Sequential batch collector for `collectBullmqJobs` callbacks (@Sendable).
final class BatchCollector: @unchecked Sendable {
    private(set) var batches: [[DisplayValue]] = []
    var count: Int { batches.count }
    var flattened: [DisplayValue] { batches.flatMap { $0 } }

    func append(_ batch: [DisplayValue]) {
        batches.append(batch)
    }
}
