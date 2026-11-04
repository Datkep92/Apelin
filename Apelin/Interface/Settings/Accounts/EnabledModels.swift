import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
///
/// Kept per configuration (`AgentAccount.id`) — two OpenAI-compatible
/// endpoints pick their models apart — except for the two providers the
/// reader adds endpoints to itself, an OpenAI-compatible one and an Anthropic
/// API key: those keep one preference per endpoint, shared by every key
/// pointing at it, so a key added later already offers the models the
/// endpoint's first key chose. What a single sign-in saved before
/// configurations had ids is read for the provider's first one, and is
/// cleared with it.
enum EnabledModels {
    private static func key(_ prefix: String, _ id: String) -> String {
        "\(prefix).\(id)"
    }

    /// The provider-wide keys a single sign-in kept: read for the provider's
    /// first configuration, cleared when it signs out.
    private static func legacyKey(_ prefix: String, _ account: AgentAccount) -> String {
        key(prefix, account.provider.rawValue)
    }

    /// What a preference is kept under: the whole Base URL for a provider the
    /// reader adds endpoints to — an OpenAI-compatible one, or an Anthropic
    /// API key — and the configuration itself for every other one, which
    /// keeps a single sign-in of its own.
    ///
    /// The Base URL, not its host: two keys on one host but at two addresses
    /// (`/v1` and `/v2`, or an `http` and an `https` one) serve different
    /// model lists, so they are two trees; two spellings of one address
    /// (`…/v1/` and `…/v1`, with or without the scheme) are one.
    static func identity(for account: AgentAccount) -> String {
        guard AgentProfileID.canonicalID(for: account.provider) != nil else { return account.id }
        if let endpoint = account.endpoint {
            return "\(account.provider.rawValue).\(endpoint)"
        }
        // A key that has not saved its Base URL yet keeps the list it had
        // when only the host was known.
        if let host = account.account, !host.isEmpty {
            return hostIdentity(for: account, host: host)
        }
        return account.id
    }

    /// What a list was kept under before the whole Base URL travelled with an
    /// account: the endpoint's host. Read, never written.
    private static func hostIdentity(for account: AgentAccount, host: String) -> String {
        "\(account.provider.rawValue).\(host)"
    }

    /// The endpoint's list, else the one an earlier version kept under the
    /// host or under this configuration, else — for a provider's first
    /// configuration — what a single sign-in left under the provider's own
    /// name.
    private static func read(_ prefix: String, _ account: AgentAccount) -> [String]? {
        let defaults = UserDefaults.standard
        if let shared = defaults.stringArray(forKey: key(prefix, identity(for: account))) {
            return shared
        }
        if let host = account.account, !host.isEmpty,
           let byHost = defaults.stringArray(forKey: key(prefix, hostIdentity(for: account, host: host)))
        {
            return byHost
        }
        if let own = defaults.stringArray(forKey: key(prefix, account.id)) {
            return own
        }
        guard account.profileID == nil else { return nil }
        return defaults.stringArray(forKey: legacyKey(prefix, account))
    }

    private static let modelsPrefix = "enabledModels"
    private static let customPrefix = "customModels"
    private static let hiddenPrefix = "hiddenModels"
    private static let prefixes = [modelsPrefix, customPrefix, hiddenPrefix]

    static func ids(for account: AgentAccount) -> Set<String> {
        Set(read(modelsPrefix, account) ?? [])
    }

    static func customIDs(for account: AgentAccount) -> [String] {
        read(customPrefix, account) ?? []
    }

    static func hiddenIDs(for account: AgentAccount) -> Set<String> {
        Set(read(hiddenPrefix, account) ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for account: AgentAccount) {
        let defaults = UserDefaults.standard
        let scope = identity(for: account)
        let shared = scope != account.id
        for (prefix, values) in [
            (modelsPrefix, models.sorted()),
            (customPrefix, custom.sorted()),
            (hiddenPrefix, hidden.sorted()),
        ] {
            defaults.set(values, forKey: key(prefix, scope))
            // The endpoint's Base URL is the one that counts, so a copy an
            // earlier version kept for this key goes. A copy kept under the
            // host stays: another key on that host but at another address
            // may still be reading it.
            if shared {
                defaults.removeObject(forKey: key(prefix, account.id))
            }
        }
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    /// A key given up: what this configuration saved goes, and the endpoint
    /// keeps its own — another key points at it, and the models it serves
    /// are the endpoint's, not this key's.
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
