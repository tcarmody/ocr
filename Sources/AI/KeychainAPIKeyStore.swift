import Foundation
import Security

/// Generic Keychain-backed API key store. Holds the cross-provider
/// keychain plumbing in one place; provider-specific stores
/// (`AnthropicAPIKeyStore`, `VoyageAPIKeyStore`, etc.) wrap this with
/// their bundle-id-scoped service suffix so they have identity in
/// the keychain.
///
/// API keys are sensitive; we don't keep them in `UserDefaults` (a
/// plain plist a backup tool can grab) or in plain files. Each key
/// is one keychain item, scoped by service name + account name.
///
/// Read / write / delete are blocking calls into the Security
/// framework. They're fast (single keychain lookup) so we don't
/// async them, but the store is `Sendable` and safe to call from
/// any task.
public struct KeychainAPIKeyStore: Sendable {

    public let service: String
    /// Account name. One value today (`"default"`); held behind a
    /// parameter so a future multi-tenant story (e.g. one key per
    /// workspace) doesn't have to migrate.
    public let account: String

    public init(service: String, account: String = "default") {
        self.service = service
        self.account = account
    }

    // MARK: - CRUD

    /// Read the stored key, or nil if none is set.
    public func read() -> String? {
        var query = baseQuery()
        query[kSecMatchLimit as String]   = kSecMatchLimitOne
        query[kSecReturnData as String]   = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Write `value` to the keychain. If a key already exists, it's
    /// overwritten in place (no duplicate items). Throws on
    /// unexpected keychain errors so the caller can surface the
    /// status code in a Settings UI alert.
    public func write(_ value: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery()

        // Probe for an existing item; update-in-place if found.
        let probe = SecItemCopyMatching(query as CFDictionary, nil)
        switch probe {
        case errSecSuccess:
            let updates: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            // Restrict accessibility to "after first unlock", so
            // background processing can read the key without
            // bouncing the user back through unlock — but the key
            // never leaves an unlocked device.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }
        default:
            throw KeychainError.unexpectedStatus(probe)
        }
    }

    /// Remove the stored key. No-op if no key exists.
    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// True when a key is currently stored. Cheap probe — useful for
    /// the Settings UI to render "Key configured" without revealing
    /// the value itself.
    public var hasKey: Bool {
        read() != nil
    }

    // MARK: - Helpers

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
    }

    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
                return "Keychain error \(s): \(msg)"
            }
        }
    }
}
