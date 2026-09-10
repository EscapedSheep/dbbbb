import Foundation
import dbbbbCore

/// A validated BullMQ job query, ready to run against the state indexes.
/// Field rules mirror the Electron reference's `parseBullmqJobQuery`.
struct ResolvedBullmqJobQuery: Sendable {
    var queue: String
    var state: BullmqJobState
    var from: Double?
    var to: Double?
    var name: String?
    var whereClauses: [(path: String, expected: DisplayValue)]?
    var includeLogs: Bool
    var limit: Int
    var scanBudget: Int
    var cursor: Int
}

enum BullmqQueryParser {
    static let defaultLimit = 100
    static let maxLimit = 500
    static let defaultScanBudget = 5_000
    static let maxScanBudget = 50_000

    /// Parses and validates the JSON text of a `.bullmqJobs` command.
    /// Errors carry the Electron reference's exact wording.
    static func parse(_ text: String) throws -> ResolvedBullmqJobQuery {
        guard let parsed = BullmqJSON.parse(text) else {
            throw BullmqAdapterError.invalidQuery("Invalid BullMQ query JSON. Check quotes, commas, and braces.")
        }
        guard case .object(let fields) = parsed else {
            throw BullmqAdapterError.invalidQuery("A BullMQ job query must be one JSON object.")
        }
        func field(_ name: String) -> DisplayValue? {
            pairsLookup(fields, name)
        }

        guard case .string(let rawQueue)? = field("queue"),
              !rawQueue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              rawQueue.count <= 512 else {
            throw BullmqAdapterError.invalidQuery("BullMQ job query queue is invalid.")
        }
        guard case .string(let rawState)? = field("state"),
              let state = BullmqJobState(rawValue: rawState) else {
            let known = BullmqJobState.allCases.map(\.rawValue).joined(separator: ", ")
            throw BullmqAdapterError.invalidQuery("BullMQ job query state must be one of: \(known).")
        }
        let from = try optionalNumber(field("from"), label: "from")
        let to = try optionalNumber(field("to"), label: "to")
        if let from, let to, from > to {
            throw BullmqAdapterError.invalidQuery("BullMQ job query from must not be after to.")
        }
        var name: String?
        if let rawName = field("name") {
            guard case .string(let value) = rawName, !value.isEmpty, value.count <= 512 else {
                throw BullmqAdapterError.invalidQuery("BullMQ job query name is invalid.")
            }
            name = value
        }
        var whereClauses: [(path: String, expected: DisplayValue)]?
        if let rawWhere = field("where") {
            guard case .object(let clauses) = rawWhere else {
                throw BullmqAdapterError.invalidQuery("BullMQ job query where must be one JSON object.")
            }
            var validated: [(path: String, expected: DisplayValue)] = []
            for clause in clauses {
                guard !clause.key.isEmpty, clause.key.count <= 256, !clause.key.contains("\0") else {
                    throw BullmqAdapterError.invalidQuery("BullMQ job query where paths are invalid.")
                }
                validated.append((clause.key, clause.value))
            }
            whereClauses = validated
        }
        var includeLogs = false
        if let rawIncludeLogs = field("includeLogs") {
            guard case .bool(let value) = rawIncludeLogs else {
                throw BullmqAdapterError.invalidQuery("BullMQ job query includeLogs is invalid.")
            }
            includeLogs = value
        }
        return ResolvedBullmqJobQuery(
            queue: rawQueue.trimmingCharacters(in: .whitespacesAndNewlines),
            state: state,
            from: from,
            to: to,
            name: name,
            whereClauses: whereClauses,
            includeLogs: includeLogs,
            limit: try boundedInteger(field("limit"), fallback: defaultLimit, maximum: maxLimit, label: "limit"),
            scanBudget: try boundedInteger(field("scanBudget"), fallback: defaultScanBudget, maximum: maxScanBudget, label: "scanBudget"),
            cursor: try cursor(field("cursor")))
    }

    /// First match wins, mirroring JS property lookup.
    private static func pairsLookup(_ pairs: [(key: String, value: DisplayValue)], _ key: String) -> DisplayValue? {
        pairs.first(where: { $0.key == key })?.value
    }

    private static func optionalNumber(_ value: DisplayValue?, label: String) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let number) = value, number.isFinite, number >= 0 else {
            throw BullmqAdapterError.invalidQuery("BullMQ job query \(label) is invalid.")
        }
        return number
    }

    private static func boundedInteger(_ value: DisplayValue?, fallback: Int, maximum: Int, label: String) throws -> Int {
        guard let value else { return fallback }
        guard case .number(let number) = value,
              number == number.rounded(), number >= 1, number <= Double(Int.max) else {
            throw BullmqAdapterError.invalidQuery("BullMQ job query \(label) is invalid.")
        }
        return min(Int(number), maximum)
    }

    private static func cursor(_ value: DisplayValue?) throws -> Int {
        guard let value else { return 0 }
        guard case .number(let number) = value,
              number == number.rounded(), number >= 0, number <= Double(Int.max) else {
            throw BullmqAdapterError.invalidQuery("BullMQ job query cursor is invalid.")
        }
        return Int(number)
    }
}

/// Glob matching with `*` as the only wildcard — literal segments matched in
/// order, anchored at both ends. Equivalent to the reference's RegExp
/// translation but linear-time (no regex backtracking).
public enum BullmqGlobMatcher {
    public static func matches(_ pattern: String, _ value: String) -> Bool {
        let segments = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if segments.count == 1 { return pattern == value }
        var index = value.startIndex
        for (position, segment) in segments.enumerated() {
            guard !segment.isEmpty else { continue }
            let anchoredAtStart = position == 0
            let anchoredAtEnd = position == segments.count - 1 && !pattern.hasSuffix("*")
            if anchoredAtStart {
                guard value.hasPrefix(segment) else { return false }
                index = value.index(index, offsetBy: segment.count)
            } else if anchoredAtEnd {
                guard value[index...].hasSuffix(segment) else { return false }
                index = value.endIndex
            } else if let range = value[index...].range(of: segment) {
                index = range.upperBound
            } else {
                return false
            }
        }
        // A pattern ending in "*" accepts any tail; otherwise the value must
        // be fully consumed by the anchored final segment.
        return pattern.hasSuffix("*") || index == value.endIndex
    }
}

enum BullmqDocumentMatcher {
    /// Equality by canonical JSON serialization, exactly the reference's
    /// `JSON.stringify(left) === JSON.stringify(right)`.
    static func wireEquals(_ left: DisplayValue, _ right: DisplayValue) -> Bool {
        BullmqJSON.stringify(left) == BullmqJSON.stringify(right)
    }

    /// Digs a dot path through object fields; absent segments yield nil.
    static func digDataPath(_ data: DisplayValue?, path: String) -> DisplayValue? {
        var current = data
        for segment in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            guard case .object(let pairs) = current,
                  let next = pairs.first(where: { $0.key == segment })?.value else { return nil }
            current = next
        }
        return current
    }

    /// Content filters: name glob, where dot-path equality, and — for
    /// `prioritized` only — the from/to range matched in memory against the
    /// job's own timestamp (the zset score packs priority into the high bits,
    /// so a score window would be meaningless).
    static func matches(_ document: DisplayValue, query: ResolvedBullmqJobQuery) -> Bool {
        if let name = query.name {
            guard case .object(let pairs) = document,
                  case .string(let documentName)? = pairs.first(where: { $0.key == "name" })?.value,
                  BullmqGlobMatcher.matches(name, documentName) else { return false }
        }
        if let whereClauses = query.whereClauses {
            let data = digDataPath(document, rootKey: "data")
            for clause in whereClauses {
                guard let actual = digDataPath(data, path: clause.path),
                      wireEquals(actual, clause.expected) else { return false }
            }
        }
        if query.state == .prioritized, query.from != nil || query.to != nil {
            guard case .object(let pairs) = document,
                  case .number(let timestamp)? = pairs.first(where: { $0.key == "timestamp" })?.value
            else { return false }
            if let from = query.from, timestamp < from { return false }
            if let to = query.to, timestamp > to { return false }
        }
        return true
    }

    private static func digDataPath(_ document: DisplayValue, rootKey: String) -> DisplayValue? {
        guard case .object(let pairs) = document else { return nil }
        return pairs.first(where: { $0.key == rootKey })?.value
    }
}

/// Editor-text surgery for BullMQ queries. Used by Continue scan: only the
/// cursor moves to the returned nextCursor; the editor text itself stays
/// untouched so a fresh Run starts from the top.
public enum BullmqQueryText {
    /// Returns `text` re-serialized with `cursor` set, preserving the other
    /// keys and their order; nil when the text is not a single JSON object.
    public static func settingCursor(_ cursor: Int, in text: String) -> String? {
        guard case .object(var pairs)? = BullmqJSON.parse(text) else { return nil }
        if let index = pairs.firstIndex(where: { $0.key == "cursor" }) {
            pairs[index] = ("cursor", .number(Double(cursor)))
        } else {
            pairs.append(("cursor", .number(Double(cursor))))
        }
        return BullmqJSON.stringify(.object(pairs))
    }

    /// Queue and state of a query text, for history titles.
    public static func queueAndState(of text: String) -> (queue: String, state: String)? {
        guard case .object(let pairs)? = BullmqJSON.parse(text),
              case .string(let queue)? = pairs.first(where: { $0.key == "queue" })?.value,
              case .string(let state)? = pairs.first(where: { $0.key == "state" })?.value
        else { return nil }
        return (queue, state)
    }
}
