import Foundation
import Security

/// Minimal Keychain wrapper for the credentials Vista holds.
///
/// Both the session token and any saved-account passwords are credentials for
/// an account that can read and write an entire Ark workspace, so they belong
/// in the Keychain rather than UserDefaults.
enum Keychain {
    private static let service = "com.derekruths.vista.session"
    /// Saved-account passwords live under their own service so clearing a
    /// session never touches them.
    private static let accountsService = "com.derekruths.vista.accounts"

    static func set(_ value: String?, for account: String) {
        write(value, service: service, account: account)
    }

    static func get(_ account: String) -> String? {
        read(service: service, account: account)
    }

    // MARK: - Saved-account passwords

    static func setPassword(_ password: String?, forAccountID id: String) {
        write(password, service: accountsService, account: id)
    }

    static func password(forAccountID id: String) -> String? {
        read(service: accountsService, account: id)
    }

    // MARK: - Storage

    private static func write(_ value: String?, service: String, account: String) {
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

    private static func read(service: String, account: String) -> String? {
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
