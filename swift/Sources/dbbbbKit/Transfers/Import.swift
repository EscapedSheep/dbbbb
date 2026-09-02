import Foundation
import dbbbbCore

/// File formats accepted for import.
public enum ImportFormat: String, Sendable, Equatable, CaseIterable {
    case csv, jsonl

    /// UTTypes-style file extension used by the open panel.
    public var fileExtensions: [String] {
        switch self {
        case .csv: ["csv"]
        case .jsonl: ["jsonl", "ndjson"]
        }
    }
}

/// Progress counters for a running import. `bytes` is raw input consumed.
public struct ImportProgress: Sendable, Equatable {
    public var processed: Int
    public var inserted: Int
    public var failed: Int
    public var bytes: Int
    public init(processed: Int = 0, inserted: Int = 0, failed: Int = 0, bytes: Int = 0) {
        self.processed = processed; self.inserted = inserted
        self.failed = failed; self.bytes = bytes
    }
}

/// Final import counts (the Electron `ImportResult` shape).
public struct ImportSummary: Sendable, Equatable {
    public let processed: Int
    public let inserted: Int
    public let failed: Int
    public init(processed: Int, inserted: Int, failed: Int) {
        self.processed = processed; self.inserted = inserted; self.failed = failed
    }
}

/// Import failures. Every message is pre-redacted: files are only ever "the
/// selected import file", never a path, and server details arrive already
/// sanitized by the adapters.
public enum ImportError: dbbbbError, Equatable {
    case cancelled
    /// Format/target mismatch, read-only guardrail, or unknown target.
    case unsupported(String)
    case fileUnavailable
    case fileUnreadable
    case fileEmpty
    case fileTooLarge
    case headerInvalid(detail: String)
    case columnCount(record: Int, expected: Int, actual: Int)
    case documentType(line: Int)
    case parseFailure(detail: String)
    case insertFailed(record: Int, detail: String)
    case rowLimit(maximum: Int)

    public var userMessage: String {
        switch self {
        case .cancelled:
            "Import was cancelled."
        case .unsupported(let detail):
            detail
        case .fileUnavailable:
            "The selected import file is no longer available."
        case .fileUnreadable:
            "The selected import file cannot be read. Check its permissions."
        case .fileEmpty:
            "The selected import file is empty. Choose a file containing rows or documents."
        case .fileTooLarge:
            "Import files are limited to 1 GB in this build."
        case .headerInvalid(let detail):
            "The CSV could not be imported: \(detail)"
        case .columnCount(let record, let expected, let actual):
            "CSV record \(record) has \(actual) columns; \(expected) were expected."
        case .documentType(let line):
            "JSONL line \(line) must contain one JSON document."
        case .parseFailure(let detail):
            detail
        case .insertFailed(let record, let detail):
            "Import stopped at record \(record): \(detail)"
        case .rowLimit(let maximum):
            "Import stopped at its configured row limit of \(maximum)."
        }
    }
}

/// One reviewed import request. `fileURL` never leaves the adapter layer —
/// errors must reference it only as "the selected import file".
public struct ImportRequest: Sendable {
    public let target: DatabaseObject
    public let format: ImportFormat
    public let fileURL: URL
    /// CSV only: whether the first record holds column names.
    public let hasHeader: Bool
    /// Cooperative cancellation; adapters check it per record and per batch.
    public let isCancelled: @Sendable () -> Bool
    /// Best-effort progress callback; must never throw.
    public let onProgress: @Sendable (ImportProgress) -> Void

    public init(
        target: DatabaseObject,
        format: ImportFormat,
        fileURL: URL,
        hasHeader: Bool,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (ImportProgress) -> Void = { _ in }
    ) {
        self.target = target; self.format = format; self.fileURL = fileURL
        self.hasHeader = hasHeader; self.isCancelled = isCancelled
        self.onProgress = onProgress
    }
}
