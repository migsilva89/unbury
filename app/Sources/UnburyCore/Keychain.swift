import Foundation
import Security

/// The OpenRouter key, kept where macOS keeps secrets rather than in a file
/// beside the data. Nothing else in this app is secret.
public enum Keychain {
    private static let service = "com.migsilva.unbury"
    /// The name the app was signed under while it was called Vault. A key
    /// saved then is still the person's key, so read it and move it over
    /// instead of asking them to paste it again.
    private static let formerService = "com.migsilva.vault"
    private static let account = "openrouter"

    public static func read(account: String) -> String? {
        if let found = read(account: account, from: service) { return found }
        guard let inherited = read(account: account, from: formerService) else { return nil }
        write(account: account, value: inherited)
        return inherited
    }

    private static func read(account: String, from service: String) -> String? {
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

    @discardableResult
    public static func write(account: String, value: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    public static func readKey() -> String? { read(account: account) }

    @discardableResult
    public static func writeKey(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

public extension Keychain {
    /// A key per service, because the two paid jobs are no longer bought from
    /// the same company. Everything here goes through `read(account:)`, so the
    /// key saved while the app was called Vault is still found and moved over.
    ///
    /// `readKey`/`writeKey` above are the OpenRouter pair under exactly the
    /// account they have always used, and stay as they are: an existing key must
    /// keep being found by every caller that has ever asked for it.
    static func read(_ service: VectorService) -> String? { read(account: service.account) }

    @discardableResult
    static func write(_ service: VectorService, key: String) -> Bool {
        write(account: service.account, value: key)
    }

    /// Forget a key, for the person who pasted the wrong one into the wrong
    /// field. Emptying the field and saving has to mean something.
    @discardableResult
    static func forget(_ service: VectorService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: service.account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
