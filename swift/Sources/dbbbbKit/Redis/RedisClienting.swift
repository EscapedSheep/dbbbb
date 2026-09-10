import Foundation

/// The command surface the BullMQ adapter needs from a Redis client. The real
/// implementation is `RedisConnection`; unit tests inject an in-memory fake
/// (mirroring the Electron reference's `BullmqRedisClient` seam).
public protocol RedisClienting: Sendable {
    func connect() async throws
    func ping() async throws
    /// One SCAN step: cursor in, next cursor + matching keys out.
    func scan(cursor: String, match: String, count: Int) async throws -> (nextCursor: String, keys: [String])
    func zcard(_ key: String) async throws -> Int
    func zcount(_ key: String, min: String, max: String) async throws -> Int
    func llen(_ key: String) async throws -> Int
    func zrange(_ key: String, start: Int, stop: Int) async throws -> [String]
    func lrange(_ key: String, start: Int, stop: Int) async throws -> [String]
    /// ZRANGEBYSCORE with an inclusive min/max and a mandatory LIMIT window.
    func zrangebyscore(_ key: String, min: String, max: String, offset: Int, count: Int) async throws -> [String]
    func hgetall(_ key: String) async throws -> [String: String]
    /// Sends a batch in one round trip; each command's reply or server error
    /// lands in its own slot, in command order.
    func pipeline(_ commands: [[String]]) async throws -> [RedisPipelineReply]
    /// EVAL with explicit keys and arguments.
    func eval(_ script: String, keys: [String], arguments: [String]) async throws -> RedisValue
    func disconnect() async
}
