import Foundation
import Security

enum Keychain {
    private static let service = "com.growthstudio.roko"

    static var claudeAPIKey: String? {
        get { read("claude-api-key") }
        set { write(newValue, "claude-api-key") }
    }

    /// The key to roko's own sync space (to-dos, shopping, links), as "<space>.<secret>".
    static var syncKey: String? {
        get { read("sync-key") }
        set { write(newValue, "sync-key") }
    }

    private static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String?, _ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
