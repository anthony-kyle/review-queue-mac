import Foundation
import ReviewQueueCore
import Security

/// Generic-password items under the app's bundle id.
enum Keychain {
    static let linearOAuthAccount = "linear-oauth-tokens"
    static let legacyLinearKeyAccount = "linear-api-key"

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    /// The Linear OAuth grant's JSON, for `LinearTokenProvider`.
    static let linearTokenStorage = LinearTokenProvider.Storage(
        read: { read(linearOAuthAccount) },
        write: { write($0, account: linearOAuthAccount) },
        delete: { delete(linearOAuthAccount) }
    )

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.bundleId, kSecAttrAccount as String: account]
    }
}
