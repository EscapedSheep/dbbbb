import Foundation
import dbbbbCore

/// Errors from the Redis client layer. Messages are pre-redacted: no
/// passwords, no credential-bearing URLs, bounded length — the same rules the
/// Electron reference applies (`safeRedisError`).
public enum RedisError: dbbbbError, Equatable {
    case authenticationFailed
    case unreachable
    case timedOut
    case closed
    case unexpectedReply
    case server(String)

    public var userMessage: String {
        switch self {
        case .authenticationFailed: "Redis authentication failed. Check the password."
        case .unreachable: "Could not reach Redis. Check the host, port, TLS setting, and network access."
        case .timedOut: "Redis operation timed out."
        case .closed: "The Redis connection is closed."
        case .unexpectedReply: "Redis returned an unexpected reply."
        case .server(let message): message
        }
    }
}

public enum RedisErrorMapper {
    private static let maxMessageLength = 600

    /// Maps any client-layer failure to a redacted `RedisError`, mirroring the
    /// Electron reference's classification (auth vs reachability vs other).
    public static func map(_ error: any Error) -> RedisError {
        if let redisError = error as? RedisError { return redisError }
        let message = String(describing: error)
        if message.range(of: #"NOAUTH|WRONGPASS|invalid username-password|AUTH failed"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .authenticationFailed
        }
        if message.range(of: #"ECONNREFUSED|ENOTFOUND|ETIMEDOUT|ECONNRESET|EHOSTUNREACH|timed out|connect"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .unreachable
        }
        return .server("Redis error: \(redact(message))")
    }

    /// Server `-ERR` text: auth wording is classified, anything else is
    /// redacted and length-capped.
    public static func mapServerError(_ text: String) -> RedisError {
        if text.range(of: #"NOAUTH|WRONGPASS|invalid username-password|AUTH failed"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .authenticationFailed
        }
        return .server("Redis error: \(redact(text))")
    }

    /// Strips credential-bearing URLs, control characters, and over-length
    /// tails. Passwords never appear: the client only ever quotes server text.
    static func redact(_ message: String) -> String {
        var result = message.replacing(#/(?i)redis(?:s)?://[^\s@/]+@/#, with: { _ in "redis://[credentials]@" })
        result = result.replacing(#/[\u{0}-\u{1F}\u{7F}]+/#, with: { _ in " " })
        if result.count > maxMessageLength {
            result = String(result.prefix(maxMessageLength))
        }
        return result
    }
}
