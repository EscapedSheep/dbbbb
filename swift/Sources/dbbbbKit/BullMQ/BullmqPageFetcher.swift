import Foundation
import dbbbbCore

/// One page read against a state index: slice the index, HGETALL each id,
/// skip ids whose hash vanished, stop backfilling after `backfillLimit`
/// extra entries (a long run of deleted jobs must not make one page read the
/// whole index). Mirrors the Electron reference's `BullmqPageRequest`.
public struct BullmqPageRequest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case zset, list
    }

    public var indexKey: String
    /// `<prefix>:<queue>:` — job hashes and logs keys derive from it.
    public var jobKeyPrefix: String
    public var kind: Kind
    public var offset: Int
    public var count: Int
    /// Zset score bounds; nil means the whole index.
    public var minScore: String?
    public var maxScore: String?
    public var includeLogs = false

    public init(indexKey: String, jobKeyPrefix: String, kind: Kind, offset: Int, count: Int, minScore: String? = nil, maxScore: String? = nil, includeLogs: Bool = false) {
        self.indexKey = indexKey; self.jobKeyPrefix = jobKeyPrefix; self.kind = kind
        self.offset = offset; self.count = count
        self.minScore = minScore; self.maxScore = maxScore; self.includeLogs = includeLogs
    }
}

public struct BullmqPageEntry: Sendable, Equatable {
    public var id: String
    public var fields: [String: String]
    public var logs: [String]?
    public var logsTotal: Int?

    public init(id: String, fields: [String: String], logs: [String]? = nil, logsTotal: Int? = nil) {
        self.id = id; self.fields = fields; self.logs = logs; self.logsTotal = logsTotal
    }
}

public struct BullmqPage: Sendable, Equatable {
    /// Index entries examined, including ids whose job hash has vanished.
    public var consumed: Int
    public var entries: [BullmqPageEntry]

    public init(consumed: Int, entries: [BullmqPageEntry]) {
        self.consumed = consumed; self.entries = entries
    }
}

/// The injectable page-fetch seam (the reference wraps its Lua script the
/// same way so unit tests can run the identical logic over a fake client).
public protocol BullmqPageFetching: Sendable {
    func fetch(_ request: BullmqPageRequest) async throws -> BullmqPage
}

public enum BullmqPageFetcher {
    public static let backfillLimit = 1_000
    public static let logsTail = 100

    /// One server-side round trip per page. ARGV: job key prefix, kind,
    /// offset, count, min score ('' = unbounded), max score, backfill limit,
    /// includeLogs flag. Ported verbatim from the Electron reference.
    static let luaScript = """
    local ids
    local offset = tonumber(ARGV[3])
    local count = tonumber(ARGV[4])
    local backfill = tonumber(ARGV[7])
    if ARGV[2] == 'zset' then
      if ARGV[5] ~= '' then
        ids = redis.call('ZRANGEBYSCORE', KEYS[1], ARGV[5], ARGV[6], 'LIMIT', offset, count + backfill)
      else
        ids = redis.call('ZRANGE', KEYS[1], offset, offset + count + backfill - 1)
      end
    else
      ids = redis.call('LRANGE', KEYS[1], offset, offset + count + backfill - 1)
    end
    local entries = {}
    local consumed = 0
    for _, id in ipairs(ids) do
      consumed = consumed + 1
      local fields = redis.call('HGETALL', ARGV[1] .. id)
      if #fields > 0 then
        if ARGV[8] == '1' then
          local logsKey = ARGV[1] .. id .. ':logs'
          local logsTotal = redis.call('LLEN', logsKey)
          local logs = redis.call('LRANGE', logsKey, -100, -1)
          table.insert(entries, {id, fields, logs, logsTotal})
        else
          table.insert(entries, {id, fields})
        end
        if #entries >= count then break end
      end
    end
    return {consumed, entries}
    """
}

/// The Lua fetcher: the production path against a real Redis.
struct BullmqLuaPageFetcher: BullmqPageFetching {
    let client: any RedisClienting

    func fetch(_ request: BullmqPageRequest) async throws -> BullmqPage {
        let reply = try await client.eval(
            BullmqPageFetcher.luaScript,
            keys: [request.indexKey],
            arguments: [
                request.jobKeyPrefix,
                request.kind.rawValue,
                String(request.offset),
                String(request.count),
                request.minScore ?? "",
                request.maxScore ?? "",
                String(BullmqPageFetcher.backfillLimit),
                request.includeLogs ? "1" : "0",
            ])
        guard case .array(let topLevel) = reply,
              let topLevel, topLevel.count == 2,
              case .array(let rawEntries) = topLevel[1], let rawEntries else {
            throw RedisError.unexpectedReply
        }
        let consumed = try Self.asCount(topLevel[0])
        let entries = try rawEntries.map { entry -> BullmqPageEntry in
            guard case .array(let parts) = entry, let parts, parts.count >= 2,
                  case .bulk(let id) = parts[0], let id,
                  case .array(let flat) = parts[1], let flat else {
                throw RedisError.unexpectedReply
            }
            var fields: [String: String] = [:]
            var index = 0
            while index + 1 < flat.count {
                guard case .bulk(let name) = flat[index], let name,
                      case .bulk(let value) = flat[index + 1] else {
                    throw RedisError.unexpectedReply
                }
                fields[name] = value
                index += 2
            }
            var result = BullmqPageEntry(id: id, fields: fields)
            if request.includeLogs {
                guard parts.count >= 4, case .array(let logs) = parts[2] else {
                    throw RedisError.unexpectedReply
                }
                result.logs = try (logs ?? []).map { line in
                    guard case .bulk(let text) = line, let text else { throw RedisError.unexpectedReply }
                    return text
                }
                result.logsTotal = try Self.asCount(parts[3])
            }
            return result
        }
        return BullmqPage(consumed: consumed, entries: entries)
    }

    /// Counts cross as integers (or numeric strings); safe and non-negative.
    static func asCount(_ value: RedisValue) throws -> Int {
        let number: Double
        switch value {
        case .integer(let integer): number = Double(integer)
        case .bulk(let text?), .status(let text):
            guard let parsed = Double(text) else { throw RedisError.unexpectedReply }
            number = parsed
        default: throw RedisError.unexpectedReply
        }
        guard number == number.rounded(), number >= 0, number <= 9_007_199_254_740_992 else {
            throw RedisError.unexpectedReply
        }
        return Int(number)
    }
}

/// The same paging logic in plain commands, used with injected fake clients
/// in unit tests; the integration suite pins parity between the two fetchers.
public struct BullmqJsPageFetcher: BullmqPageFetching {
    private let client: any RedisClienting

    public init(client: any RedisClienting) {
        self.client = client
    }

    public func fetch(_ request: BullmqPageRequest) async throws -> BullmqPage {
        let fetchSize = request.count + BullmqPageFetcher.backfillLimit
        let ids: [String]
        switch request.kind {
        case .zset:
            if let minScore = request.minScore {
                ids = try await client.zrangebyscore(
                    request.indexKey, min: minScore, max: request.maxScore ?? "+inf",
                    offset: request.offset, count: fetchSize)
            } else {
                ids = try await client.zrange(
                    request.indexKey, start: request.offset, stop: request.offset + fetchSize - 1)
            }
        case .list:
            ids = try await client.lrange(
                request.indexKey, start: request.offset, stop: request.offset + fetchSize - 1)
        }

        var commands: [[String]] = []
        for id in ids {
            commands.append(["hgetall", "\(request.jobKeyPrefix)\(id)"])
            if request.includeLogs {
                commands.append(["lrange", "\(request.jobKeyPrefix)\(id):logs", "-\(BullmqPageFetcher.logsTail)", "-1"])
                commands.append(["llen", "\(request.jobKeyPrefix)\(id):logs"])
            }
        }
        let replies = commands.isEmpty ? [] : try await client.pipeline(commands)

        var entries: [BullmqPageEntry] = []
        var consumed = 0
        var replyIndex = 0
        for id in ids {
            consumed += 1
            let fields = try Self.hashReply(replies, at: &replyIndex)
            var logs: [String]?
            var logsTotal: Int?
            if request.includeLogs {
                logs = try Self.stringArrayReply(replies, at: &replyIndex)
                logsTotal = try Self.countReply(replies, at: &replyIndex)
            }
            if fields.isEmpty { continue }
            entries.append(BullmqPageEntry(id: id, fields: fields, logs: logs, logsTotal: logsTotal))
            if entries.count >= request.count { break }
        }
        return BullmqPage(consumed: consumed, entries: entries)
    }

    private static func reply(_ replies: [RedisPipelineReply], at index: inout Int) throws -> RedisValue {
        defer { index += 1 }
        guard index < replies.count else { throw RedisError.unexpectedReply }
        switch replies[index] {
        case .value(let value): return value
        case .error(let text): throw RedisErrorMapper.mapServerError(text)
        }
    }

    private static func hashReply(_ replies: [RedisPipelineReply], at index: inout Int) throws -> [String: String] {
        guard case .array(let flat) = try reply(replies, at: &index) else { throw RedisError.unexpectedReply }
        guard let flat else { return [:] }
        var fields: [String: String] = [:]
        var cursor = 0
        while cursor + 1 < flat.count {
            guard case .bulk(let name) = flat[cursor], let name,
                  case .bulk(let value) = flat[cursor + 1] else { throw RedisError.unexpectedReply }
            fields[name] = value
            cursor += 2
        }
        return fields
    }

    private static func stringArrayReply(_ replies: [RedisPipelineReply], at index: inout Int) throws -> [String] {
        guard case .array(let elements) = try reply(replies, at: &index) else { throw RedisError.unexpectedReply }
        return try (elements ?? []).map { element in
            guard case .bulk(let text) = element, let text else { throw RedisError.unexpectedReply }
            return text
        }
    }

    private static func countReply(_ replies: [RedisPipelineReply], at index: inout Int) throws -> Int {
        try BullmqLuaPageFetcher.asCount(reply(replies, at: &index))
    }
}
