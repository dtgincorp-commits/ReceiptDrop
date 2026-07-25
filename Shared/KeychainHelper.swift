import Foundation
import Security

/// Minimal Keychain wrapper. Items are stored in the App Group's shared
/// keychain access group so both the main app and the share extension
/// can read them. On iOS, an App Group ID can be used directly as a
/// keychain access group — no separate Keychain Sharing capability needed.
enum KeychainError: LocalizedError {
    case encoding
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encoding:
            return "Couldn't encode the key as text."
        case .status(let status):
            if status == errSecMissingEntitlement {
                return "Missing App Group / Keychain entitlement (status \(status)) — " +
                    "this usually means the current build was signed without App Group " +
                    "access (e.g. a free Personal Team, which doesn't support App Groups)."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain write failed: \(message) (status \(status))"
        }
    }
}

enum KeychainHelper {
    private static let service = "com.dtgincorp.receiptdrop"

    /// The shared query targets the App Group's keychain access group so the
    /// main app and share extension see the same items. `includeAccessGroup:
    /// false` drops that attribute, targeting the app's own private keychain
    /// instead — used as a fallback when the shared write is rejected for a
    /// missing entitlement (a free Personal Team build, which can't have App
    /// Groups). On a properly-signed build the shared path always succeeds, so
    /// the fallback never runs and behavior is unchanged.
    private static func baseQuery(for account: String, includeAccessGroup: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if includeAccessGroup {
            query[kSecAttrAccessGroup as String] = AppConstants.appGroupID
        }
        return query
    }

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        (try? setDetailed(value, for: account)) != nil
    }

    /// Same write, but surfaces the actual `OSStatus` on failure instead of
    /// collapsing it to `false` — a missing-entitlement error (e.g. no App
    /// Group access under a free Personal Team signing) looks identical to
    /// "did nothing" otherwise, which makes it undiagnosable from the UI.
    static func setDetailed(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }
        do {
            try add(data, for: account, includeAccessGroup: true)
        } catch KeychainError.status(errSecMissingEntitlement) {
            // No App Group entitlement (Personal Team build) — fall back to the
            // app's private keychain so local main-app testing still works. The
            // share extension won't see the item in this mode, which is fine
            // since App Groups aren't available to test the extension anyway.
            try add(data, for: account, includeAccessGroup: false)
        }
    }

    private static func add(_ data: Data, for account: String, includeAccessGroup: Bool) throws {
        // Delete any existing item first, then add fresh.
        SecItemDelete(baseQuery(for: account, includeAccessGroup: includeAccessGroup) as CFDictionary)
        var query = baseQuery(for: account, includeAccessGroup: includeAccessGroup)
        query[kSecValueData as String] = data
        // Accessible after first unlock so the share extension can read it
        // even if invoked shortly after a reboot before first unlock ends.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.status(status)
        }
    }

    static func get(_ account: String) -> String? {
        // Shared access group first, then the private-keychain fallback used by
        // Personal Team builds.
        if let value = read(account, includeAccessGroup: true) {
            return value
        }
        return read(account, includeAccessGroup: false)
    }

    private static func read(_ account: String, includeAccessGroup: Bool) -> String? {
        var query = baseQuery(for: account, includeAccessGroup: includeAccessGroup)
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
        // Clear both locations so a "Remove" always fully clears the key
        // regardless of which path stored it.
        let shared = SecItemDelete(baseQuery(for: account, includeAccessGroup: true) as CFDictionary)
        let priv = SecItemDelete(baseQuery(for: account, includeAccessGroup: false) as CFDictionary)
        return shared == errSecSuccess || priv == errSecSuccess
    }
}
