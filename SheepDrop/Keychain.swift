import Foundation
import Security

/// Passwords live ONLY in the macOS Keychain, service `Bestchaan.SheepDrop`,
/// keyed by "user@host:port". Same rule as SheepTerm: nothing password-shaped
/// is ever written to disk by this app.
///
/// nonisolated: SecItem* is thread-safe, and reads are deliberately made off
/// the main actor — SecItemCopyMatching is an IPC round-trip that can block on
/// the SecurityAgent prompt.
nonisolated enum Keychain {
    private static let service = "Bestchaan.SheepDrop"

    static func account(for host: HostEntry) -> String {
        "\(host.username)@\(host.address):\(host.port)"
    }

    @discardableResult
    static func setPassword(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
