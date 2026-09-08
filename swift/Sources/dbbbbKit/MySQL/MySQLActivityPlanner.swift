import Foundation
import dbbbbCore

/// Pure command + row parsing for the MySQL activity viewer (ROADMAP M2 ⑨).
enum MySQLActivityPlanner {
    /// FULL so the Info column carries the complete statement; the excerpt
    /// cap is applied client-side in `activity`.
    static let listActivitySQL = "SHOW FULL PROCESSLIST"

    /// `KILL` (full connection kill), not `KILL QUERY`: a process list entry
    /// is a session, and stopping only its current statement would leave the
    /// row listed. The id was parsed from the process list, never user text.
    static func killStatement(threadID: UInt64) -> String {
        "KILL \(threadID)"
    }

    /// Maps one process-list row; nil when the Id cell is missing (the row is
    /// then unusable as a kill target and is dropped). Numeric columns cross
    /// as text (`SHOW` hands them over as strings); the Info excerpt is
    /// capped to the shared statement limit.
    static func activity(
        id: UInt64?,
        user: String?,
        database: String?,
        command: String?,
        state: String?,
        timeSeconds: UInt64?,
        info: String?
    ) -> ServerActivity? {
        guard let id else { return nil }
        return ServerActivity(
            id: String(id),
            user: user,
            database: database,
            statement: info.map { ServerActivity.truncatedStatement($0) },
            age: timeSeconds.map { .seconds(Int64(clamping: $0)) },
            state: command ?? state)
    }

    /// Parses a numeric process-list cell; missing/unparseable → nil.
    static func uint64(_ text: String?) -> UInt64? {
        guard let text else { return nil }
        return UInt64(text.trimmingCharacters(in: .whitespaces))
    }
}
