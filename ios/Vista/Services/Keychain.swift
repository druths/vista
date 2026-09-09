import Foundation
import Security

/// Minimal Keychain wrapper for the Vista session token.
///
/// The session token is a bearer credential for an account that can read and
/// write an entire Ark workspace, so it belongs in the Keychain rather than
/// UserDefaults.
enum Keychain {
    private static let service = "com.derekruths.vista.session"

    static func set(_ value: String?, for account: String) {
        // Delete first: SecItemUpdate has more edge cases than it's worth here.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }

        var insert = query
        insert[kSecValueData as String] = data
        // The token is only needed while the app is in use; this keeps it off
        // iCloud Keychain and out of backups.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
