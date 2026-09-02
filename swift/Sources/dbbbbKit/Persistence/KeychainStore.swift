import Foundation
import Security
import dbbbbCore

/// Errors from credential storage. Messages are pre-redacted: they never
/// contain secrets, connection details, or local paths.
public enum KeychainStoreError: dbbbbError, Equatable {
    case readFailed
    case writeFailed

    public var userMessage: String {
        switch self {
        case .readFailed: "A saved credential could not be read from the Keychain."
        case .writeFailed: "The credential could not be saved to the Keychain."
        }
    }
}

/// Credential vault. Secrets are keyed only by the connection UUID; the store
/// never sees names, hosts, or any other connection detail.
public protocol KeychainStore: Sendable {
    func secret(for id: UUID) throws -> String?
    func setSecret(_ secret: String, for id: UUID) throws
    func removeSecret(for id: UUID) throws
}

/// Security-framework store: one generic-password item per connection,
/// service `dev.dbbbb.connection`, account = the connection UUID.
public struct SecurityKeychainStore: KeychainStore {
    private let service: String

    public init(service: String = "dev.dbbbb.connection") {
        self.service = service
    }

    public func secret(for id: UUID) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(for: id, returning: true) as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.readFailed
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.readFailed
        }
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let base = query(for: id, returning: false)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainStoreError.writeFailed }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw KeychainStoreError.writeFailed
        }
    }

    public func removeSecret(for id: UUID) throws {
        let status = SecItemDelete(query(for: id, returning: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.writeFailed
        }
    }

    private func query(for id: UUID, returning: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString.lowercased()
        ]
        if returning {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

/// Test double: keeps secrets in memory, never touches the real Keychain.
public final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: String] = [:]

    public init() {}

    public func secret(for id: UUID) throws -> String? {
        lock.withLock { secrets[id] }
    }

    public func setSecret(_ secret: String, for id: UUID) throws {
        lock.withLock { secrets[id] = secret }
    }

    public func removeSecret(for id: UUID) throws {
        lock.withLock { secrets[id] = nil }
    }
}
