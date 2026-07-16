import Foundation
import Security

/// Minimal Keychain wrapper. Items are stored in the App Group's shared
/// keychain access group so both the main app and the share extension
/// can read them. On iOS, an App Group ID can be used directly as a
/// keychain access group — no separate Keychain Sharing capability needed.
enum KeychainHelper {
    private static let service = "com.dtgincorp.receiptdrop"

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppConstants.appGroupID,
        ]
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete any existing item first, then add fresh.
        SecItemDelete(baseQuery(for: account) as CFDictionary)
        var query = baseQuery(for: account)
        query[kSecValueData as String] = data
        // Accessible after first unlock so the share extension can read it
        // even if invoked shortly after a reboot before first unlock ends.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        SecItemDelete(baseQuery(for: account) as CFDictionary) == errSecSuccess
    }
}
