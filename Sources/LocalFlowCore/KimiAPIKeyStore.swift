import Foundation
import Security

/// The user's Kimi API key in the login keychain (never plain preferences).
public enum KimiAPIKeyStore {
    private static let service = "dev.localflow.app"
    private static let account = "kimi-api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
