import Foundation
import dbbbbCore

/// The engine adapter contract. Implementations own one live session.
/// Editing (`applyDataChange`) and importing (`importData`) are optional capabilities:
/// adapters that do not support them simply leave them unimplemented via `SupportsEditing` /
/// `SupportsImporting`, and callers must fail closed.
public protocol DatabaseAdapter: Sendable {
    var profile: ConnectionProfile { get }
    func listObjects() async throws -> [DatabaseObject]
    func previewObject(_ object: DatabaseObject) async throws -> QueryResult
    func execute(_ command: DatabaseCommand, options: ExecuteOptions) async throws -> QueryResult
    /// Best-effort cancellation of a running request. Engines without server-side
    /// interruption throw `AdapterError.cancellationUnsupported`.
    func cancel(requestID: UUID) async throws
    func close() async
}

/// Optional editing capability (safe single-record changes with optimistic concurrency).
public protocol SupportsEditing: DatabaseAdapter {
    func applyDataChange(_ change: DataChange) async throws -> QueryResult
}

/// Optional import capability (streaming file import into one known target).
/// Adapters re-check the read-only guardrail themselves; callers must also
/// fail closed when the adapter does not conform.
public protocol SupportsImporting: DatabaseAdapter {
    func importData(_ request: ImportRequest) async throws -> ImportSummary
}

public enum AdapterError: dbbbbError, Equatable {
    case cancellationUnsupported
    case engineMismatch
    case sessionClosed
    case readOnlyViolation
    case notFound(String)

    public var userMessage: String {
        switch self {
        case .cancellationUnsupported: "This engine cannot cancel a running query; statements run to completion."
        case .engineMismatch: "The command does not match this connection's engine."
        case .sessionClosed: "The connection is closed."
        case .readOnlyViolation: "This session is read-only."
        case .notFound(let what): what
        }
    }
}

/// A reviewed single-record change (update or delete) against one known object.
public struct DataChange: Sendable {
    public enum Operation: Sendable {
        case update(changed: [String: DisplayValue])
        case delete
    }
    public let object: DatabaseObject
    /// Original values as previously displayed — the optimistic-concurrency baseline.
    public let original: [String: DisplayValue]
    public let operation: Operation
    public init(object: DatabaseObject, original: [String: DisplayValue], operation: Operation) {
        self.object = object; self.original = original; self.operation = operation
    }
}
