import Foundation
import Security

/// Thin Keychain wrapper for the API keys Cheboo holds. Each credential is a
/// separate generic-password item under one shared service, keyed by account,
/// so switching engines never means re-pasting a key you already entered.
enum Keychain {
    static let service = "com.github.velet5.cheboo"

    enum Account: String {
        case deepgram = "deepgram_api_key"
        /// Used by the `gptTranscribe` engine.
        case openAI = "openai_api_key"
    }

    static func save(_ apiKey: String, for account: Account) {
        let data = apiKey.data(using: .utf8) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(base as CFDictionary)

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Keychain.save(\(account.rawValue)) failed: \(status)")
        }
    }

    static func load(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
