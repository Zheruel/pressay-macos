import Foundation
import Security

/// One API key in the login keychain (never plain preferences).
public struct KeychainSecret: Sendable {
    private let service = "dev.localflow.app"
    private let account: String

    public init(account: String) {
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ key: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

public enum ClaudeAPIKeyStore {
    private static let secret = KeychainSecret(account: "claude-api-key")
    public static func read() -> String? { secret.read() }
    @discardableResult public static func save(_ key: String) -> Bool { secret.save(key) }
    public static func clear() { secret.clear() }
}

/// The user’s OpenAI API key, stored separately from subscription credentials.
public enum OpenAIAPIKeyStore {
    private static let secret = KeychainSecret(account: "openai-api-key")
    public static func read() -> String? { secret.read() }
    @discardableResult public static func save(_ key: String) -> Bool { secret.save(key) }
    public static func clear() { secret.clear() }
}
