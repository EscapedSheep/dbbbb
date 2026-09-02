import Foundation
import dbbbbCore

/// Errors raised by the MySQL adapter. Messages are pre-redacted and safe to show in the UI.
public enum MySQLAdapterError: dbbbbError, Equatable {
    case invalidConfiguration
    case duplicateRequestID
    case cancelled
    case timedOut
    case connectTimedOut
    /// Read-only SQL the classifier could not prove safe; it fails closed.
    case unclassifiableSQL(position: Int)
    case multipleStatements
    case statementNotReadOnly
    case forbiddenToken(String)
    /// An already-sanitized engine/transport failure message.
    case failure(String)

    public var userMessage: String {
        switch self {
        case .invalidConfiguration:
            "The MySQL connection settings are invalid."
        case .duplicateRequestID:
            "A MySQL query with this request id is already running."
        case .cancelled:
            "MySQL query was cancelled."
        case .timedOut:
            "MySQL query timed out."
        case .connectTimedOut:
            "Could not connect to MySQL: connection timed out."
        case .unclassifiableSQL(let position):
            "Read-only mode could not safely classify SQL near character \(position)."
        case .multipleStatements:
            "Read-only connections only allow one SQL statement at a time."
        case .statementNotReadOnly:
            "Read-only connections only allow read-only SQL statements."
        case .forbiddenToken(let token):
            "Read-only connections do not allow the SQL token \(token)."
        case .failure(let message):
            message
        }
    }
}
