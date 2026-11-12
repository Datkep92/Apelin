import ApelinProtocol
import Foundation

/// An ordered list of model/configurations to try when the current one fails
/// with HTTP 429. Same provider (other configurations) comes first, then
/// other providers that offer the same model name, then the rest.
struct ModelCandidate: Equatable {
    let account: AgentAccount
    let model: String
}

extension ModelCandidate {
    /// This model as the selection a prompt sends with, with what the
    /// catalog says it offers. The reader's effort and speed are kept apart
    /// (`ComposerModelPreferences`), so a model that lacks them does not
    /// lose them.
    var selection: ComposerModelSelection {
        ComposerModelSelection(
            provider: account.provider,
            model: model,
            profileID: account.profileID,
            supportedEfforts: (account.reasoningEfforts?[model] ?? []).filter { [.low, .high, .max].contains($0) },
            supportedTiers: account.serviceTiers?[model] ?? [],
        )
    }
}

extension ComposerModelSelection {
    /// What a cooldown is kept under: the configuration and the model — not
    /// the reader's effort or speed, which another key answers the same way.
    /// Two keys are two of these, and one key that serves a model under two
    /// names is two more.
    var retryKey: String {
        "\(provider.rawValue)|\(profileID ?? "")|\(model)"
    }
}

extension ModelRetryState {
    /// The next candidate to send, in fallback order. A candidate that failed
    /// is stepped over while its cooldown runs — unless the reader asked
    /// themselves, which spends it anyway.
    func nextCandidate(readerAsked: Bool, now: Date = Date()) -> ComposerModelSelection? {
        remaining.first { selection in
            guard !triedKeys.contains(selection.retryKey) else { return false }
            guard !readerAsked, let until = cooldowns?[selection.retryKey] else { return true }
            return until <= now
        }
    }
}

enum ModelCandidates {
    /// `keys` read as a ring whose first place is the key in hand: that key,
    /// then the ones after it, then the ones before it and round again. The
    /// order itself is the list's own (`ModelKeys.serving`) — this only moves
    /// where reading it starts, so a walk down the list wraps back to its top
    /// instead of jumping there. Unchanged when the key in hand is not one of
    /// them.
    static func circular(_ keys: [AgentAccount], from current: AgentAccount?) -> [AgentAccount] {
        guard let current, let place = keys.firstIndex(where: { $0.id == current.id }) else {
            return keys
        }
        return Array(keys[place...]) + Array(keys[..<place])
    }

    /// Builds the fallback order starting after `current`. `current` itself is
    /// excluded; if nothing else is available the list is empty (caller keeps
    /// the current selection). Accounts must already be filtered to signed-in,
    /// enabled ones (see `EnabledModels.accounts(from:)`).
    ///
    /// Another key on the *same Base URL*, with the same model, comes first —
    /// the very keys the key control offers, in its order
    /// (`ModelKeys.serving`), read from the key in hand and round
    /// (`circular(_:from:)`), so a switch and a fallback walk them the same
    /// way and a walk remembers where it stood instead of starting at the
    /// list's first key every time: that is what a spent allowance or a
    /// refused key needs, and it is the one swap that costs the conversation
    /// nothing. Then the same model
    /// on the provider's family, then that model name on any other provider —
    /// every key for the model in hand before any other model. Only after
    /// those the reader's other enabled models, and those only where the
    /// reader turned the switch on (`ModelFallback.triesOtherModels`): a
    /// different model is a different answer, and a conversation that changes
    /// model on its own is not what the reader asked for.
    static func fallbackList(
        current: ComposerModelSelection?,
        accounts: [AgentAccount],
        otherModels: Bool = false,
    ) -> [ModelCandidate] {
        let enabled = EnabledModels.accounts(from: accounts)
        guard let current else {
            return enabled.flatMap { account in
                (account.models ?? []).map { ModelCandidate(account: account, model: $0) }
            }
        }
        var result: [ModelCandidate] = []
        var seen: Set<String> = []

        func add(_ candidate: ModelCandidate) {
            let key = "\(candidate.account.id)|\(candidate.model)"
            guard seen.insert(key).inserted else { return }
            result.append(candidate)
        }

        func isCurrent(_ account: AgentAccount) -> Bool {
            account.provider == current.provider && account.profileID == current.profileID
        }

        func offers(_ account: AgentAccount, _ model: String) -> Bool {
            (account.models ?? []).contains(model)
        }

        // 1. The same model on another key of the same Base URL, in the order
        // the key control lists them, read from the key in hand and round: the
        // keys after it, then the ones before it. The walk goes down the list
        // and wraps back to its top, so the key in hand's place is what decides
        // where the next one is — never the first key of the list.
        let currentAccount = enabled.first(where: isCurrent)
            ?? enabled.first(where: { $0.provider == current.provider && offers($0, current.model) })
        let sameAddress = ModelKeys.serving(current.model, at: currentAccount?.endpoint, from: enabled)
        for account in circular(sameAddress, from: currentAccount) where !isCurrent(account) {
            add(ModelCandidate(account: account, model: current.model))
        }
        // 2. The same model, another configuration of the provider's family.
        for account in enabled
            where !isCurrent(account) && account.provider.modelFamily == current.provider.modelFamily
                && offers(account, current.model)
        {
            add(ModelCandidate(account: account, model: current.model))
        }
        // 3. The same model name, anywhere else.
        for account in enabled
            where account.provider.modelFamily != current.provider.modelFamily && offers(account, current.model)
        {
            add(ModelCandidate(account: account, model: current.model))
        }
        // 4. Another model the reader enabled, on the provider's own family
        // first, and 5. the rest: both only on the reader's own say-so.
        guard otherModels else { return result }
        for account in enabled
            where !isCurrent(account) && account.provider.modelFamily == current.provider.modelFamily
        {
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        for account in enabled where account.provider.modelFamily != current.provider.modelFamily {
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        return result
    }
}

extension AgentProvider {
    /// Providers that are the same brand under different regional sites are
    /// one family: another configuration of the same plan counts as the same
    /// brand when an allowance runs out, not another. The enum cases stay
    /// wire-stable; only the steps above read it, which is why it lives here
    /// and not with the names Settings shows.
    var modelFamily: AgentProvider {
        switch self {
        case .qoderCN: return .qoder
        case .workBuddyAI: return .workBuddy
        case .zaiCodingCN: return .zai
        default: return self
        }
    }
}
