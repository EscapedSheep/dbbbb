import Foundation
import dbbbbCore

/// Hash→document conversion and object-id resolution, mirroring the Electron
/// reference's `bullmqJobHashToDocument` / `resolveBullmqObjectId`.
enum BullmqDocumentMapper {
    /// Converts one job hash to a display document; nil for an empty/vanished
    /// hash (the index entry is then skipped but still counted as scanned).
    /// Field order is stable: id, queue, state, then payload fields.
    static func jobHashToDocument(
        id: String,
        queue: String,
        state: BullmqJobState,
        hash: [String: String]
    ) -> DisplayValue? {
        guard !hash.isEmpty else { return nil }
        var pairs: [(key: String, value: DisplayValue)] = [
            ("id", .string(id)),
            ("queue", .string(queue)),
            ("state", .string(state.rawValue)),
        ]
        if let name = hash["name"], !name.isEmpty { pairs.append(("name", .string(name))) }
        if let raw = hash["data"], let data = BullmqJSON.parse(raw) { pairs.append(("data", data)) }
        if let raw = hash["opts"], let opts = BullmqJSON.parse(raw) { pairs.append(("opts", opts)) }
        for field in ["timestamp", "processedOn", "finishedOn", "delay"] {
            if let value = numericField(hash[field]) { pairs.append((field, .number(value))) }
        }
        // BullMQ ≥5 stores attemptsMade under the short `atm` key; older
        // producers may still write the long form.
        if let value = numericField(hash["atm"] ?? hash["attemptsMade"]) {
            pairs.append(("attemptsMade", .number(value)))
        }
        if let failedReason = hash["failedReason"], !failedReason.isEmpty {
            pairs.append(("failedReason", .string(failedReason)))
        }
        if let stacktrace = parseStacktrace(hash["stacktrace"]) {
            pairs.append(("stacktrace", .array(stacktrace.map(DisplayValue.string))))
        }
        return .object(pairs)
    }

    /// Resolves a navigator node id against the known queues: `<queue>` or
    /// `<queue>:<state>`, with the state tail matched in reverse so queue
    /// names may themselves contain colons.
    static func resolveObjectID(
        _ queues: Set<String>,
        objectID: String
    ) -> (queue: String, state: BullmqJobState?)? {
        if queues.contains(objectID) { return (objectID, nil) }
        for state in BullmqJobState.allCases {
            let suffix = ":\(state.rawValue)"
            if objectID.hasSuffix(suffix) {
                let queue = String(objectID.dropLast(suffix.count))
                if !queue.isEmpty, queues.contains(queue) { return (queue, state) }
            }
        }
        return nil
    }

    private static func numericField(_ raw: String?) -> Double? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// BullMQ versions differ: some store a JSON array, others a raw string
    /// (split into lines here, like the reference).
    private static func parseStacktrace(_ raw: String?) -> [String]? {
        guard let raw, !raw.isEmpty else { return nil }
        if let parsed = BullmqJSON.parse(raw), case .array(let lines) = parsed {
            return lines.map { line in
                if case .string(let text) = line { return text }
                return BullmqJSON.stringify(line)
            }
        }
        return raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
