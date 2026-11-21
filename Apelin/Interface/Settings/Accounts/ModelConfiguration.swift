import ApelinProtocol
import Foundation

/// One named Base URL of a provider, holding any number of API keys.
///
/// This is what `+` adds in Settings: a name and an address, with the keys
/// added to it afterwards. Keys saved under the same provider and the same
/// canonical Base URL join it — they share its name and the models enabled for
/// that address. The group outlives its keys: signing the last one out leaves
/// the named configuration waiting for another, which is why its name is also
/// kept in `PendingConfigurations`.
struct ModelConfiguration: Hashable {
    var provider: AgentProvider
    /// `AgentEndpoint.canonical`: the whole address, path included. Two keys
    /// at `/v1` and `/v2` on one host are two configurations, because the
    /// models behind them are two lists.
    var baseURL: String

    /// The record that keeps the group's name and keeps it when it is empty.
    var storageID: String {
        PendingConfigurations.storageID(provider: provider, baseURL: baseURL)
    }

    /// The configuration of a key in the listing: the provider and the address
    /// it points at. A key whose Base URL did not travel with it is grouped by
    /// the host it reported, as it was before the whole address was known.
    static func from(_ account: AgentAccount) -> ModelConfiguration? {
        guard AgentProfileID.canonicalID(for: account.provider) != nil else { return nil }
        let baseURL: String?
        if let canonical = account.endpoint {
            baseURL = canonical
        } else if let host = account.account, !host.isEmpty {
            baseURL = AgentEndpoint.canonical(host) ?? host
        } else {
            baseURL = nil
        }
        guard let baseURL else { return nil }
        return ModelConfiguration(provider: account.provider, baseURL: baseURL)
    }

    /// What Settings and the detail page call this group: a rename the reader
    /// asked for, else the name its keys were saved under, else the bare
    /// address.
    func title(keys: [AgentAccount]) -> String {
        if let renamed = PendingConfigurations.name(for: storageID) { return renamed }
        return keys.first { $0.name != nil }?.name ?? AgentEndpoint.title(baseURL)
    }

    /// A key of this group, not signed in yet: its name and address are already
    /// known, so the sign-in page has only the secret to ask for.
    func newAccount(id: String, method: AgentSignInMethod, alternativeMethods: [AgentSignInMethod]?) -> AgentAccount {
        AgentAccount(
            provider: provider,
            id: id,
            method: method,
            alternativeMethods: alternativeMethods,
            signedIn: false,
            name: title(keys: []),
            baseURL: baseURL,
        )
    }
}
