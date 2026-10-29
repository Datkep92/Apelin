import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
///
/// Kept per configuration (`AgentAccount.id`), so two Anthropic API keys or
/// two OpenAI-compatible endpoints pick their models apart. What a single
/// sign-in saved before configurations had ids is read for the provider's
/// first one, and is cleared with it.
enum EnabledModels {
    private static func key(_ prefix: String, _ id: String) -> String {
        "\(prefix).\(id)"
    }

    /// The provider-wide keys a single sign-in kept: read for the provider's
    /// first configuration, cleared when it signs out.
    private static func legacyKey(_ prefix: String, _ account: AgentAccount) -> String {
        key(prefix, account.provider.rawValue)
    }

    private static let modelsPrefix = "enabledModels"
    private static let customPrefix = "customModels"
    private static let hiddenPrefix = "hiddenModels"
    private static let prefixes = [modelsPrefix, customPrefix, hiddenPrefix]

    static func ids(for account: AgentAccount) -> Set<String> {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: key(modelsPrefix, account.id)) {
            return Set(saved)
        }
        guard account.profileID == nil else { return [] }
        return Set(defaults.stringArray(forKey: legacyKey(modelsPrefix, account)) ?? [])
    }

    static func customIDs(for account: AgentAccount) -> [String] {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: key(customPrefix, account.id)) {
            return saved
        }
        guard account.profileID == nil else { return [] }
        return defaults.stringArray(forKey: legacyKey(customPrefix, account)) ?? []
    }

    static func hiddenIDs(for account: AgentAccount) -> Set<String> {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: key(hiddenPrefix, account.id)) {
            return Set(saved)
        }
        guard account.profileID == nil else { return [] }
        return Set(defaults.stringArray(forKey: legacyKey(hiddenPrefix, account)) ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for account: AgentAccount) {
        UserDefaults.standard.set(models.sorted(), forKey: key(modelsPrefix, account.id))
        UserDefaults.standard.set(custom.sorted(), forKey: key(customPrefix, account.id))
        UserDefaults.standard.set(hidden.sorted(), forKey: key(hiddenPrefix, account.id))
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for account: AgentAccount) {
        let defaults = UserDefaults.standard
        for prefix in prefixes {
            defaults.removeObject(forKey: key(prefix, account.id))
            // The first configuration also lets go of what a single sign-in
            // saved; an added one leaves that alone.
            if account.profileID == nil {
                defaults.removeObject(forKey: legacyKey(prefix, account))
            }
        }
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            let ids = ids(for: account).subtracting(hiddenIDs(for: account))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
