import Foundation
import dbbbbCore
import PostgresNIO

/// User-facing adapter error. `message` is always pre-sanitized — no
/// passwords, credential-bearing URIs, or control characters. `sqlState`
/// carries the server SQLSTATE when one was reported.
public struct PostgresAdapterError: dbbbbError, Equatable {
    public let message: String
    public let sqlState: String?
    public init(message: String, sqlState: String? = nil) {
        self.message = message
        self.sqlState = sqlState
    }
    public var userMessage: String { message }
}

/// Scrubs driver/server errors for display, ported from the Electron
/// adapter's `sanitizedError`: secrets (raw and percent-encoded),
/// credential-bearing `postgres://` URIs, and `password=`-style fragments are
/// redacted; control characters are stripped and the result is length-capped.
/// The SQLSTATE is preserved when it is well-formed.
enum PostgresErrorSanitizer {
    static let maxLength = 600

    static func sanitized(action: String, error: any Error, secrets: [String]) -> PostgresAdapterError {
        var message = describe(error)

        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "[redacted]")
            let encoded = percentEncode(secret)
            if encoded != secret {
                message = message.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }

        message = replacing(
            #"\bpostgres(?:ql)?://[^\s/@]+(?::[^@\s]*)?@"#,
            in: message, with: "postgresql://[redacted]@")
        message = replacing(
            #"\b(password|passwd|pwd)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
            in: message, with: "$1=[redacted]")
        message = String(String.UnicodeScalarView(message.unicodeScalars.map {
            $0.value < 0x20 || $0.value == 0x7F ? " " : $0
        }))
        message = replacing(#"\s+"#, in: message, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > maxLength {
            message = String(message.prefix(maxLength))
        }

        return PostgresAdapterError(
            message: "\(action): \(message.isEmpty ? "Unexpected database error." : message)",
            sqlState: sqlState(of: error))
    }

    static func describe(_ error: any Error) -> String {
        if let psqlError = error as? PSQLError {
            if let serverMessage = psqlError.serverInfo?[.message], !serverMessage.isEmpty {
                return serverMessage
            }
            return "PostgreSQL driver error (\(psqlError.code))."
        }
        return String(describing: error)
    }

    static func sqlState(of error: any Error) -> String? {
        guard let psqlError = error as? PSQLError,
              let state = psqlError.serverInfo?[.sqlState],
              state.range(of: #"^[0-9A-Z]{5}$"#, options: .regularExpression) != nil
        else { return nil }
        return state
    }

    /// JS `encodeURIComponent`: everything except A-Z a-z 0-9 `-_.!~*'()` is
    /// percent-encoded from UTF-8 bytes with uppercase hex.
    static func percentEncode(_ string: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        var result = ""
        for byte in string.utf8 {
            let scalar = Unicode.Scalar(byte)
            if allowed.contains(Character(scalar)) {
                result.append(Character(scalar))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// A resolved navigator object. `name` is nil for schema nodes.
struct PostgresObjectRef: Sendable, Equatable {
    enum Kind: String, Sendable {
        case schema, table, view
    }
    let kind: Kind
    let schema: String
    let name: String?
}

/// Opaque object handles: base64url-encoded JSON `[kind, schema, name|null]`
/// with a `postgresql:` prefix, matching the Electron adapter's encoding.
enum PostgresObjectIDCodec {
    static func encode(_ ref: PostgresObjectRef) -> String {
        let array: [Any] = [ref.kind.rawValue, ref.schema, ref.name ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: array) else {
            return "postgresql:"
        }
        let base64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "postgresql:" + base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    static func decode(_ id: String) -> PostgresObjectRef? {
        guard id.hasPrefix("postgresql:") else { return nil }
        var base64 = String(id.dropFirst("postgresql:".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              array.count == 3,
              let kindRaw = array[0] as? String,
              let kind = PostgresObjectRef.Kind(rawValue: kindRaw),
              let schema = array[1] as? String
        else { return nil }
        let name = array[2] is NSNull ? nil : array[2] as? String
        if kind != .schema && name == nil { return nil }
        return PostgresObjectRef(kind: kind, schema: schema, name: name)
    }
}
