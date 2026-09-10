import Foundation
import dbbbbCore

/// Errors surfaced by the BullMQ adapter. Messages are pre-redacted and match
/// the Electron reference's wording (its tests pin these strings).
enum BullmqAdapterError: dbbbbError, Equatable {
    case invalidConfiguration
    case invalidOptions
    case engineMismatch
    case commandRejected
    case closed
    case unknownObject
    case duplicateRequest
    case cancelled
    case timedOut
    case invalidQuery(String)
    case redis(RedisError)

    var userMessage: String {
        switch self {
        case .invalidConfiguration: "BullMQ connection settings are invalid."
        case .invalidOptions: "BullMQ execution options are invalid."
        case .engineMismatch: "The selected connection is not a BullMQ connection."
        case .commandRejected: "The selected BullMQ connection only accepts job queries."
        case .closed: "The BullMQ connection is closed."
        case .unknownObject: "Refresh objects before previewing this BullMQ queue."
        case .duplicateRequest: "A BullMQ query with this request id is already running."
        case .cancelled: "BullMQ query cancelled."
        case .timedOut: "BullMQ query timed out."
        case .invalidQuery(let detail): detail
        case .redis(let error): error.userMessage
        }
    }
}

enum BullmqErrorMapper {
    /// Passes adapter errors through unchanged and maps everything else to a
    /// redacted Redis-layer error (mirrors the Electron `safeRedisError`).
    static func map(_ error: any Error) -> BullmqAdapterError {
        if let adapterError = error as? BullmqAdapterError { return adapterError }
        return .redis(RedisErrorMapper.map(error))
    }
}
