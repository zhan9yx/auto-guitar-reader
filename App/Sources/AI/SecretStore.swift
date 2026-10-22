import Foundation

/// Where secrets (the AI API key) live. The app uses the Keychain; tests use `InMemorySecretStore`.
protocol SecretStore {
    func string(for account: String) -> String?
    /// Stores `value` (nil / empty deletes it). Returns false when the backing store failed.
    @discardableResult
    func set(_ value: String?, for account: String) -> Bool
}

/// Non-persistent store (tests, previews, non-Apple platforms).
final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    init(_ initial: [String: String] = [:]) { values = initial }

    func string(for account: String) -> String? { values[account] }

    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        if let value, !value.isEmpty { values[account] = value } else { values[account] = nil }
        return true
    }
}

enum DefaultSecretStore {
    /// Keychain on Apple platforms.
    static func make() -> SecretStore {
        #if canImport(Security)
        return KeychainStore()
        #else
        return InMemorySecretStore()
        #endif
    }
}
