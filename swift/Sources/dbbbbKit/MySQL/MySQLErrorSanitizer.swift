import Foundation
import MySQLNIO

/// Redacts credentials and normalizes driver errors before they reach the UI.
/// Mirrors the Electron adapter (`mysql-adapter.ts`): passwords are replaced in
/// plain and URL-encoded form, credential URIs and `password=` patterns are
/// masked, control characters stripped, length capped, and the server's
/// `ER_*` error code preserved.
enum MySQLErrorSanitizer {
    static let maxMessageLength = 600

    static func sanitize(action: String, error: any Error, secrets: [String]) -> MySQLAdapterError {
        var message = rawMessage(of: error)

        for secret in secrets where !secret.isEmpty {
            message = message.replacingOccurrences(of: secret, with: "[redacted]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               encoded != secret {
                message = message.replacingOccurrences(of: encoded, with: "[redacted]")
            }
        }

        message = message.replacingOccurrences(
            of: #"\bmysql://[^\s/@]+(?::[^@\s]*)?@"#,
            with: "mysql://[redacted]@",
            options: [.regularExpression, .caseInsensitive]
        )
        message = message.replacingOccurrences(
            of: #"\b(password|passwd|pwd)\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
            with: "$1=[redacted]",
            options: [.regularExpression, .caseInsensitive]
        )
        message = message.replacingOccurrences(
            of: "[\\u{0}-\\u{1F}\\u{7F}]+",
            with: " ",
            options: .regularExpression
        )
        message = message
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if message.count > maxMessageLength {
            message = String(message.prefix(maxMessageLength))
        }

        var full = "\(action): \(message.isEmpty ? "Unexpected database error." : message)"
        if let code = serverErrorCode(of: error) {
            full += " (\(code))"
        }
        return .failure(full)
    }

    /// The server's error mnemonic with the conventional `ER_` prefix, e.g. `ER_NO_SUCH_THREAD`.
    static func serverErrorCode(of error: any Error) -> String? {
        guard case MySQLError.server(let packet) = error else { return nil }
        let name = packet.errorCode.name
        guard name.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil else { return nil }
        return "ER_\(name)"
    }

    static func serverError(_ error: any Error, is code: MySQLProtocol.ErrorCode) -> Bool {
        guard case MySQLError.server(let packet) = error else { return false }
        return packet.errorCode == code
    }

    private static func rawMessage(of error: any Error) -> String {
        if let mysqlError = error as? MySQLError {
            return mysqlError.message
        }
        return (error as NSError).localizedDescription
    }
}
