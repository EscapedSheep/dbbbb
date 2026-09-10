import Foundation

/// The eight BullMQ job states, in the fixed order the object navigator
/// reports them (mirrors the Electron reference's `BULLMQ_JOB_STATES`).
public enum BullmqJobState: String, Codable, Sendable, CaseIterable {
    case failed, completed, active, waiting, delayed, prioritized, paused
    case waitingChildren = "waiting-children"

    /// The state index key segment under `<prefix>:<queue>:` — `waiting` maps
    /// to the `wait` list; every other state keeps its own name.
    public var indexKey: String {
        self == .waiting ? "wait" : rawValue
    }

    /// Zset-backed states (scored by their relevant timestamp, except
    /// `prioritized`, whose score packs the priority into the high bits);
    /// the rest are plain lists.
    public var isZset: Bool {
        switch self {
        case .failed, .completed, .delayed, .prioritized, .waitingChildren: true
        case .active, .waiting, .paused: false
        }
    }
}

/// A plain-JSON tree with ordinary (untagged) Codable, used where arbitrary
/// JSON must cross inside a Codable struct — unlike `DisplayValue`, whose
/// kind-tagged coding is designed for the display pipeline. Object key order
/// is not preserved (Swift keyed containers do not guarantee it).
public enum PlainJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PlainJSON])
    case object([String: PlainJSON])

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([PlainJSON].self) { self = .array(value); return }
            if let value = try? container.decode([String: PlainJSON].self) { self = .object(value); return }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a JSON value."))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let pairs): try container.encode(pairs)
        }
    }

    /// Display-pipeline form. Object keys come out in sorted order (plain
    /// JSON dictionaries carry no order).
    public var displayValue: DisplayValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(\.displayValue))
        case .object(let pairs):
            .object(pairs.sorted { $0.key < $1.key }.map { ($0.key, $0.value.displayValue) })
        }
    }

    public init(_ displayValue: DisplayValue) {
        switch displayValue {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .binary(let data): self = .string(data.base64EncodedString())
        case .array(let values): self = .array(values.map(PlainJSON.init))
        case .object(let pairs): self = .object(Dictionary(pairs.map { ($0.key, PlainJSON($0.value)) }, uniquingKeysWith: { _, last in last }))
        }
    }
}

/// The editor-facing BullMQ job query (JSON text of `.bullmqJobs` commands).
/// Field validation and defaults happen in dbbbbKit's parser; this type is
/// the Codable wire shape, JSON-compatible with the Electron reference.
public struct BullmqJobQuery: Codable, Sendable, Equatable {
    public var queue: String
    public var state: BullmqJobState
    /// Millisecond timestamp bounds. Applied server-side (ZRANGEBYSCORE) for
    /// zset-backed states whose score is a plain timestamp — that excludes
    /// `prioritized`, whose range is matched in memory under the scan budget.
    public var from: Double?
    public var to: Double?
    /// Job name filter; `*` acts as a glob wildcard.
    public var name: String?
    /// Equality matches on dot paths inside the job's data payload.
    public var whereClauses: [String: PlainJSON]?
    /// Default 100, capped at 500.
    public var limit: Int?
    /// Maximum jobs scanned while content-filtering; default 5000, capped at 50000.
    public var scanBudget: Int?
    /// Offset inside the state index where scanning resumes; default 0.
    public var cursor: Int?
    /// When true, each returned job carries `logs` (last 100 lines) and `logsTotal`.
    public var includeLogs: Bool?

    public init(
        queue: String,
        state: BullmqJobState,
        from: Double? = nil,
        to: Double? = nil,
        name: String? = nil,
        whereClauses: [String: PlainJSON]? = nil,
        limit: Int? = nil,
        scanBudget: Int? = nil,
        cursor: Int? = nil,
        includeLogs: Bool? = nil
    ) {
        self.queue = queue; self.state = state
        self.from = from; self.to = to; self.name = name
        self.whereClauses = whereClauses
        self.limit = limit; self.scanBudget = scanBudget
        self.cursor = cursor; self.includeLogs = includeLogs
    }

    private enum CodingKeys: String, CodingKey {
        case queue, state, from, to, name, limit, scanBudget, cursor, includeLogs
        case whereClauses = "where"
    }
}
