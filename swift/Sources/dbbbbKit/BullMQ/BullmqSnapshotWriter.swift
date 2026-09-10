import Foundation
import dbbbbCore
import GRDB

/// Errors from snapshot writing. Messages are pre-redacted: no file paths,
/// no payload data.
public enum BullmqSnapshotError: dbbbbError, Equatable {
    case writerClosed
    case writeFailed

    public var userMessage: String {
        switch self {
        case .writerClosed: "The BullMQ snapshot writer is closed."
        case .writeFailed: "The snapshot could not be written to local storage."
        }
    }
}

/// Materializes one BullMQ queue into a local SQLite analysis table so the
/// regular SQLite workspace can run arbitrary SQL (json_extract included) over
/// the jobs. v1 deliberately rebuilds the whole table on every sync instead of
/// applying a timestamp-based incremental: jobs move between states
/// (waiting → failed → …), and an incremental keyed on finishedOn would keep
/// stale rows for jobs that changed state since the last sync — silent dirty
/// data. A full drop-and-recreate in one transaction stays correct at the cost
/// of re-reading the queue. Mirrors the Electron reference's
/// `BullmqSnapshotWriter`.
///
/// The queue name appears only as data (the `queue` column), never inside a
/// SQL identifier. All batches land in one transaction; `abort()` rolls it
/// back and the coordinator deletes the temp file.
public final class BullmqSnapshotWriter: @unchecked Sendable {
    public static let tableName = "jobs"

    private static let createTableSQL = """
    CREATE TABLE jobs (
      id TEXT,
      queue TEXT,
      state TEXT,
      name TEXT,
      data TEXT,
      opts TEXT,
      attempts_made INTEGER,
      failed_reason TEXT,
      stacktrace TEXT,
      timestamp INTEGER,
      processed_on INTEGER,
      finished_on INTEGER,
      delay INTEGER
    )
    """

    private static let createIndexesSQL = """
    CREATE INDEX idx_jobs_state ON jobs (state);
    CREATE INDEX idx_jobs_name ON jobs (name);
    CREATE INDEX idx_jobs_finished_on ON jobs (finished_on)
    """

    private static let insertSQL = """
    INSERT INTO jobs (
      id, queue, state, name, data, opts,
      attempts_made, failed_reason, stacktrace,
      timestamp, processed_on, finished_on, delay
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    private let database: DatabaseQueue
    private var open = true

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // The transaction is managed manually (one BEGIN … COMMIT spanning all
        // batches, mirroring the reference's node:sqlite lifecycle), which is
        // exactly what this flag exists for.
        var configuration = GRDB.Configuration()
        configuration.allowsUnsafeTransactions = true
        database = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        do {
            try database.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN")
                try db.execute(sql: Self.createTableSQL)
                for statement in Self.createIndexesSQL.split(separator: ";") {
                    let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { try db.execute(sql: trimmed) }
                }
            }
        } catch {
            try? database.close()
            throw error
        }
    }

    /// Inserts one collected batch inside the writer's transaction (GRDB's
    /// `writeWithoutTransaction`: the transaction is managed manually here,
    /// mirroring the reference's BEGIN/COMMIT lifecycle).
    public func insertBatch(_ jobs: [DisplayValue]) throws {
        guard open else { throw BullmqSnapshotError.writerClosed }
        do {
            try database.writeWithoutTransaction { db in
                for job in jobs {
                    guard case .object(let pairs) = job else { continue }
                    let fields = Dictionary(pairs.map { ($0.key, $0.value) }) { first, _ in first }
                    try db.execute(
                        sql: Self.insertSQL,
                        arguments: [
                            Self.asText(fields["id"]),
                            Self.asText(fields["queue"]),
                            Self.asText(fields["state"]),
                            Self.asText(fields["name"]),
                            Self.asJSONText(fields["data"]),
                            Self.asJSONText(fields["opts"]),
                            Self.asInteger(fields["attemptsMade"]),
                            Self.asText(fields["failedReason"]),
                            Self.asStacktrace(fields["stacktrace"]),
                            Self.asInteger(fields["timestamp"]),
                            Self.asInteger(fields["processedOn"]),
                            Self.asInteger(fields["finishedOn"]),
                            Self.asInteger(fields["delay"]),
                        ])
                }
            }
        } catch {
            throw BullmqSnapshotError.writeFailed
        }
    }

    /// Commits the transaction and closes the file. The coordinator renames
    /// the temp file over any previous snapshot after this returns.
    public func commit() throws {
        guard open else { return }
        do {
            try database.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
        } catch {
            try? database.close()
            open = false
            throw BullmqSnapshotError.writeFailed
        }
        try? database.close()
        open = false
    }

    /// Rolls back and closes; the transaction may already be broken, so a
    /// rollback failure is swallowed — closing still releases the file.
    public func abort() {
        guard open else { return }
        try? database.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
        try? database.close()
        open = false
    }

    // MARK: Column extraction (mirrors the reference's asText/asJsonText/…)

    private static func asText(_ value: DisplayValue?) -> String? {
        guard case .string(let text) = value, !text.isEmpty else { return nil }
        return text
    }

    private static func asJSONText(_ value: DisplayValue?) -> String? {
        guard let value else { return nil }
        return BullmqJSON.stringify(value)
    }

    private static func asInteger(_ value: DisplayValue?) -> Int64? {
        guard case .number(let number) = value,
              number.isFinite, number == number.rounded(),
              abs(number) <= 9_007_199_254_740_992 else { return nil }
        return Int64(number)
    }

    private static func asStacktrace(_ value: DisplayValue?) -> String? {
        if case .array(let lines) = value {
            return lines.map { line in
                if case .string(let text) = line { return text }
                return BullmqJSON.stringify(line)
            }.joined(separator: "\n")
        }
        return asText(value)
    }
}
