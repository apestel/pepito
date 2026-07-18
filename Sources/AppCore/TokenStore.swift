import Foundation
import Security

/// Stockage sécurisé du token d'authentification IA. Le token ne transite jamais par les réglages
/// JSON ni les logs (CLAUDE.md §9).
public protocol TokenStore: Sendable {
    func token(for account: String) throws -> String?
    func setToken(_ token: String?, for account: String) throws
}

/// Implémentation Keychain (production). Non couverte par les tests unitaires (nécessite un
/// trousseau accessible) ; la logique est isolée derrière `TokenStore` pour tester le reste.
public struct KeychainTokenStore: TokenStore {
    public let service: String

    public init(service: String = "com.pepito.app.ai-token") {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func token(for account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for account: String) throws {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    enum KeychainError: Error { case status(OSStatus) }
}

/// Implémentation en mémoire pour les tests et les previews.
public final class InMemoryTokenStore: TokenStore {
    private let storage = NSLock()
    nonisolated(unsafe) private var tokens: [String: String] = [:]

    public init() {}

    public func token(for account: String) throws -> String? {
        storage.lock(); defer { storage.unlock() }
        return tokens[account]
    }

    public func setToken(_ token: String?, for account: String) throws {
        storage.lock(); defer { storage.unlock() }
        tokens[account] = token
    }
}
