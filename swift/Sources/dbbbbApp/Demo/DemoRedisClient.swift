import Foundation
import dbbbbCore
import dbbbbKit

/// In-memory Redis for the BullMQ demo connection: the same key layout and
/// command semantics as the real server (hashes, zsets, lists, paged SCAN,
/// pipelining), seeded with two canned queues. The demo adapter embeds a real
/// `BullmqAdapter` over this client, so every BullMQ UI path — paging,
/// filters, logs, snapshots — exercises the production code.
final class DemoRedisClient: RedisClienting, @unchecked Sendable {
    private var hashes: [String: [String: String]] = [:]
    private var zsets: [String: [(member: String, score: Double)]] = [:]
    private var lists: [String: [String]] = [:]
    private var keys: Set<String> = []

    private static let prefix = "bull"

    /// The canned dataset: `emails` covers every state (failed jobs carry
    /// failedReason/stacktrace/logs in the exact shapes BullMQ writes);
    /// `reports` is a second, smaller queue so discovery shows two.
    static func seeded() -> DemoRedisClient {
        let client = DemoRedisClient()
        let base: Double = 1_756_490_000_000

        func hash(_ queue: String, _ id: String, _ fields: [String: String]) {
            client.hashes["\(prefix):\(queue):\(id)"] = fields
        }
        func zadd(_ queue: String, _ state: BullmqJobState, _ score: Double, _ id: String) {
            let key = "\(prefix):\(queue):\(state.indexKey)"
            var zset = client.zsets[key] ?? []
            zset.append((id, score))
            zset.sort { $0.score < $1.score }
            client.zsets[key] = zset
        }
        func push(_ queue: String, _ state: BullmqJobState, _ ids: [String]) {
            client.lists["\(prefix):\(queue):\(state.indexKey)", default: []].append(contentsOf: ids)
        }
        func mark(_ queue: String, _ idCount: Int) {
            client.keys.insert("\(prefix):\(queue):id")
            _ = idCount
        }

        mark("emails", 9)
        let failureNames = ["welcome-email", "invoice-email", "welcome-sms"]
        for (index, name) in failureNames.enumerated() {
            let id = String(index + 1)
            let finished = base + Double(index) * 1_000
            hash("emails", id, [
                "name": name,
                "data": #"{"userId":\#(index + 1),"user":{"id":\#(index + 1),"tier":"pro"}}"#,
                "opts": #"{"attempts":3,"backoff":{"type":"fixed","delay":1000}}"#,
                "atm": "2",
                "failedReason": "SMTP rejected recipient for \(name)",
                "stacktrace": #"["Error: SMTP rejected recipient for \#(name)","    at send (mail.js:1)"]"#,
                "timestamp": String(Int64(finished - 2_000)),
                "processedOn": String(Int64(finished - 1_000)),
                "finishedOn": String(Int64(finished)),
            ])
            client.lists["\(prefix):emails:\(id):logs"] = ["picked up", "smtp handshake", "boom"]
            zadd("emails", .failed, finished, id)
        }
        for index in 0..<2 {
            let id = String(index + 4)
            let finished = base + 10_000 + Double(index) * 1_000
            hash("emails", id, [
                "name": "welcome-email",
                "data": #"{"userId":\#(10 + index),"user":{"id":\#(10 + index),"tier":"free"}}"#,
                "opts": #"{"attempts":1}"#,
                "atm": "1",
                "timestamp": String(Int64(finished - 1_000)),
                "processedOn": String(Int64(finished - 500)),
                "finishedOn": String(Int64(finished)),
            ])
            zadd("emails", .completed, finished, id)
        }
        for index in 0..<2 {
            let id = String(index + 6)
            hash("emails", id, [
                "name": "digest-email",
                "data": #"{"userId":\#(20 + index)}"#,
                "timestamp": String(Int64(base + 20_000 + Double(index))),
            ])
        }
        push("emails", .waiting, ["6", "7"])
        hash("emails", "8", [
            "name": "invoice-email",
            "data": #"{"userId":30}"#,
            "atm": "1",
            "timestamp": String(Int64(base + 30_000)),
            "processedOn": String(Int64(base + 30_100)),
        ])
        push("emails", .active, ["8"])
        hash("emails", "9", [
            "name": "reminder-email",
            "data": #"{"userId":40}"#,
            "delay": "600000",
            "timestamp": String(Int64(base + 40_000)),
        ])
        zadd("emails", .delayed, base + 600_000, "9")
        hash("emails", "10", [
            "name": "digest-email",
            "data": #"{"userId":50}"#,
            "timestamp": String(Int64(base + 50_000)),
        ])
        push("emails", .paused, ["10"])

        mark("reports", 3)
        for index in 0..<2 {
            let id = String(index + 1)
            let finished = base + 60_000 + Double(index) * 1_000
            hash("reports", id, [
                "name": "weekly-report",
                "data": #"{"report":{"kind":"weekly"}}"#,
                "atm": "1",
                "timestamp": String(Int64(finished - 1_000)),
                "finishedOn": String(Int64(finished)),
            ])
            zadd("reports", .completed, finished, id)
        }
        hash("reports", "3", [
            "name": "nightly-report",
            "data": #"{"report":{"kind":"nightly"}}"#,
            "atm": "5",
            "failedReason": "Upstream API returned 502",
            "stacktrace": #"["Error: Upstream API returned 502"]"#,
            "timestamp": String(Int64(base + 62_000)),
            "finishedOn": String(Int64(base + 63_000)),
        ])
        zadd("reports", .failed, base + 63_000, "3")
        return client
    }

    // MARK: - RedisClienting

    func connect() async throws {}
    func ping() async throws {}
    func disconnect() async {}

    func scan(cursor: String, match: String, count: Int) async throws -> (nextCursor: String, keys: [String]) {
        let all = keys.filter { BullmqGlobMatcher.matches(match, $0) }.sorted()
        let pageSize = max(count, 1)
        let start = Int(cursor) ?? 0
        let page = Array(all.dropFirst(start).prefix(pageSize))
        let next = start + pageSize >= all.count ? "0" : String(start + pageSize)
        return (next, page)
    }

    func zcard(_ key: String) async throws -> Int { zsets[key]?.count ?? 0 }

    func zcount(_ key: String, min: String, max: String) async throws -> Int {
        let bounds = Self.scoreBounds(min: min, max: max)
        return (zsets[key] ?? []).filter { $0.score >= bounds.lo && $0.score <= bounds.hi }.count
    }

    func llen(_ key: String) async throws -> Int { lists[key]?.count ?? 0 }

    func zrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        let members = (zsets[key] ?? []).map(\.member)
        return Array(members[Self.normalizeRange(length: members.count, start: start, stop: stop)])
    }

    func lrange(_ key: String, start: Int, stop: Int) async throws -> [String] {
        let list = lists[key] ?? []
        return Array(list[Self.normalizeRange(length: list.count, start: start, stop: stop)])
    }

    func zrangebyscore(_ key: String, min: String, max: String, offset: Int, count: Int) async throws -> [String] {
        let bounds = Self.scoreBounds(min: min, max: max)
        let matched = (zsets[key] ?? [])
            .filter { $0.score >= bounds.lo && $0.score <= bounds.hi }
            .map(\.member)
        return Array(matched.dropFirst(offset).prefix(count))
    }

    func hgetall(_ key: String) async throws -> [String: String] {
        hashes[key] ?? [:]
    }

    func pipeline(_ commands: [[String]]) async throws -> [RedisPipelineReply] {
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
        throw RedisError.server("The demo Redis cannot run Lua; the JS page fetcher is used instead.")
    }

    // MARK: - Helpers

    private static func scoreBounds(min: String, max: String) -> (lo: Double, hi: Double) {
        let lo = min == "-inf" ? -Double.infinity : (Double(min) ?? 0)
        let hi = max == "+inf" ? Double.infinity : (Double(max) ?? 0)
        return (lo, hi)
    }

    /// Redis-style inclusive range with negative-index normalization.
    private static func normalizeRange(length: Int, start rawStart: Int, stop rawStop: Int) -> Range<Int> {
        let start = rawStart < 0 ? max(length + rawStart, 0) : rawStart
        let stop = rawStop < 0 ? length + rawStop : rawStop
        let clampedStop = min(stop, length - 1)
        guard start <= clampedStop, start < length else { return 0..<0 }
        return start..<(clampedStop + 1)
    }
}
