import Foundation
import Security

/// Reads/writes our own Keychain items — same-app access, so macOS never
/// shows a permission prompt for these (unlike reading another app's item).
private let keychainAccount = "relay"

private func readSecret(service: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
        return nil
    }
    return value
}

private func writeSecret(_ value: String, service: String) -> Bool {
    let data = Data(value.utf8)
    let baseQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keychainAccount
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess { return true }
    guard updateStatus == errSecItemNotFound else { return false }
    var addQuery = baseQuery
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
}

private func deleteSecret(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: keychainAccount
    ]
    SecItemDelete(query as CFDictionary)
}

/// Identifies which of Relay's two Keychain-stored secrets to operate on.
public enum RelayKeychainKey {
    case deepSeekAPIKey
    case liteLLMMasterKey
    case anthropicAPIKey
    case openAIAPIKey
    case geminiAPIKey
    case groqAPIKey

    public func service(suffix: String = "") -> String {
        let base: String
        switch self {
        case .deepSeekAPIKey: base = "com.gokul.relay.deepseek-api-key"
        case .liteLLMMasterKey: base = "com.gokul.relay.litellm-master-key"
        case .anthropicAPIKey: base = "com.gokul.relay.anthropic-api-key"
        case .openAIAPIKey: base = "com.gokul.relay.openai-api-key"
        case .geminiAPIKey: base = "com.gokul.relay.gemini-api-key"
        case .groqAPIKey: base = "com.gokul.relay2.groq-api-key"
        }
        return suffix.isEmpty ? base : "\(base).\(suffix)"
    }
}

public struct KeychainStore {
    /// Non-empty in unit tests so we never collide with the user's real items.
    public let serviceSuffix: String

    public init(serviceSuffix: String = "") {
        self.serviceSuffix = serviceSuffix
    }

    public func read(_ key: RelayKeychainKey) -> String? {
        readSecret(service: key.service(suffix: serviceSuffix))
    }

    @discardableResult
    public func write(_ value: String, for key: RelayKeychainKey) -> Bool {
        writeSecret(value, service: key.service(suffix: serviceSuffix))
    }

    public func delete(_ key: RelayKeychainKey) {
        deleteSecret(service: key.service(suffix: serviceSuffix))
    }
}
