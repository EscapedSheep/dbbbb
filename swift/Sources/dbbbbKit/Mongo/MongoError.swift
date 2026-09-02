import Foundation
import dbbbbCore
import MongoClient

/// Errors surfaced by the MongoDB adapter. Every message is pre-redacted:
/// no credentials, no credential-bearing URIs, no local paths.
enum MongoAdapterError: dbbbbError, Equatable {
    case invalidConfiguration(String)
    case invalidExtendedJSON(String)
    case writeStageRejected(String)
    case noCollectionSelected
    case duplicateRequest
    case cancelled
    case timedOut
    case unreachable
    case authenticationFailed
    case server(String)

    var userMessage: String {
        switch self {
        case .invalidConfiguration(let detail): detail
        case .invalidExtendedJSON(let detail): detail
        case .writeStageRejected(let stage): "\(stage) is disabled because it writes data."
        case .noCollectionSelected: "Select a collection before running MongoDB queries."
        case .duplicateRequest: "A MongoDB query with this request id is already running."
        case .cancelled: "MongoDB query cancelled."
        case .timedOut: "MongoDB query timed out."
        case .unreachable: "Could not reach MongoDB. Check the URI, TLS setting, and network access."
        case .authenticationFailed: "MongoDB authentication failed. Check the username and password."
        case .server(let message): message
        }
    }
}

enum MongoErrorMapper {
    private static let maxMessageLength = 600

    /// Maps any driver error to a redacted `MongoAdapterError`. Request-state
    /// flags win: a cursor closed by the timeout watchdog or by cancellation
    /// surfaces as timeout/cancellation, not as the driver's cursor error.
    static func map(_ error: Error, requestState: MongoRequestState? = nil) -> MongoAdapterError {
        if let requestState {
            if requestState.timedOut { return .timedOut }
            if requestState.cancelRequested { return .cancelled }
        }
        if error is CancellationError { return .cancelled }
        if let adapterError = error as? MongoAdapterError { return adapterError }

        if let reply = error as? MongoGenericErrorReply {
            if reply.code == 18 { return .authenticationFailed }
            if reply.code == 50 { return .timedOut }
            let label = reply.codeName ?? reply.code.map(String.init) ?? "error"
            return .server("MongoDB \(label): \(redact(reply.errorMessage ?? "Command failed."))")
        }
        if error is MongoServerError {
            return .server("MongoDB rejected the command.")
        }

        let message = (error as? dbbbbError)?.userMessage ?? String(describing: error)
        if message.range(of: #"server selection|ECONNREFUSED|ENOTFOUND|timed out|connection.*(closed|reset)"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return .unreachable
        }
        return .server(redact(message))
    }

    /// Maps write-command failures to the Electron adapter's data-change
    /// wording (`safeMongoDataChangeError`). Returns nil for codes without a
    /// specific message.
    static func mapDataChangeCode(_ code: Int?) -> MongoAdapterError? {
        switch code {
        case 18: .authenticationFailed
        case 13: .server("MongoDB did not authorize this document change.")
        case 50: .timedOut
        case 11000: .server("MongoDB rejected this change because it violates a unique index.")
        case 121: .server("MongoDB rejected this change because it violates collection validation.")
        default: nil
        }
    }

    /// Maps a failure of one document change (update/delete) to a redacted
    /// error, mirroring the Electron adapter's `safeMongoDataChangeError`.
    static func mapDataChange(_ error: Error) -> MongoAdapterError {
        if let reply = error as? MongoGenericErrorReply,
           let mapped = mapDataChangeCode(reply.code) {
            return mapped
        }
        let message = String(describing: error)
        if message.range(of: #"server selection|ECONNREFUSED|ENOTFOUND|timed out"#,
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return .server("The MongoDB server became unavailable while applying the document change.")
        }
        return .server("MongoDB could not apply the document change.")
    }

    /// Credential and URI scrubbing, same rules as the Electron reference.
    static func redact(_ message: String) -> String {
        var result = message
        result = result.replacing(#/(?i)mongodb(?:\+srv)?://[^\s@/]+@/#, with: { _ in "mongodb://[credentials]@" })
        result = result.replacing(#/(?i)(password|pwd)=([^&\s]+)/#, with: { match in "\(match.1)=[redacted]" })
        result = result.replacing(#/[\u{0}-\u{1F}\u{7F}]+/#, with: { _ in " " })
        if result.count > maxMessageLength {
            result = String(result.prefix(maxMessageLength))
        }
        return result
    }
}
