import ApelinProtocol
import Foundation

/// The keys of one Base URL, and the name each of them is shown under.
///
/// Three places read the same keys and have to agree on them: the model
/// picker's key page, the composer's key control, and the order a failed run
/// falls back through (`ModelCandidates.fallbackList`, which reads this order
/// from the key in hand and round). One order serves all three — the reader's
/// own, as the Settings listing keeps it — so switching a key never moves it,
/// and the same key is named the same way wherever it is offered. Two
/// configurations on one address are two keys of one Base URL; the same
/// configuration on another address is another Base URL's.
///
/// A key is named by what the reader called its configuration, never by a
/// secret: a key is named, never quoted.
///
/// The name itself is the app's (`AgentAccount.title`, which reads a
/// localized provider name), so it arrives as `title`: the app passes
/// `\.title`, and the transcript tests pass their own — the naming rule then
/// lives in one place and is tested where it is decided, without the
/// interface.
enum ModelKeys {
    /// The reader's enabled keys, in the listing's own order: the ones the
    /// picker and the composer offer (`EnabledModels.accounts(from:)`).
    static func enabled(_ accounts: [AgentAccount]) -> [AgentAccount] {
        EnabledModels.accounts(from: accounts)
    }

    /// The keys that can send `model` from `endpoint`, in that order: the
    /// ones the key control offers, and the ones a spent allowance or a
    /// refused key falls back through. A selection that names no Base URL
    /// offers none, and a model one of the keys does not serve is not
    /// another's to answer — every key keeps its own list of models.
    static func serving(
        _ model: String,
        at endpoint: String?,
        from accounts: [AgentAccount],
    ) -> [AgentAccount] {
        guard let endpoint else { return [] }
        return enabled(accounts).filter { account in
            account.endpoint == endpoint && (account.models ?? []).contains(model)
        }
    }

    /// What each of `keys` is called, one name per row, in the order the
    /// list is in.
    ///
    /// A key alone keeps its configuration's name: there is nothing beside
    /// it to tell it from. Where the list holds several — which is the whole
    /// point of a Base URL that keeps many keys — the name alone makes two
    /// of them read alike, so the letter of its place is added: `Relay - API
    /// Key A`, `Relay - API Key B`. The place is the list's, so the picker,
    /// the key control's menu and a fallback count the same keys the same
    /// way.
    static func labels(_ keys: [AgentAccount], title: (AgentAccount) -> String) -> [String] {
        keys.enumerated().map { index, account in
            names(for: account, at: index, of: keys.count, title: title)
        }
    }

    /// What a control that shows one of `keys` writes beside it: the key as
    /// `labels` names it where its own configuration's name is shared with
    /// another of them, and that name alone where it is not. The letter is
    /// worth the room exactly when two keys would otherwise read alike.
    static func controlName(
        for account: AgentAccount,
        among keys: [AgentAccount],
        title: (AgentAccount) -> String,
    ) -> String {
        let shared = keys.filter { title($0) == title(account) }.count > 1
        guard shared, let index = keys.firstIndex(where: { $0.id == account.id }) else {
            return title(account)
        }
        return names(for: account, at: index, of: keys.count, title: title)
    }

    /// A, B, C ..., and past the alphabet the place itself: a list that long
    /// is still told apart, and never by a secret.
    private static func letter(_ index: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard index < alphabet.count else { return String(index + 1) }
        return String(alphabet[index])
    }

    private static func names(
        for account: AgentAccount,
        at index: Int,
        of count: Int,
        title: (AgentAccount) -> String,
    ) -> String {
        guard count > 1 else { return title(account) }
        return "\(title(account)) - \(String(localized: "API Key")) \(letter(index))"
    }
}
