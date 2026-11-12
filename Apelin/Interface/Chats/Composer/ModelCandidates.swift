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

    /// The walk's own list (`ordered`) read as a ring whose place is the key
    /// in hand: the candidates after it, then the ones before it and round
    /// again. Reading it only moves where reading starts, so a walk halfway
    /// down the list reaches its top instead of stopping there, and a second
    /// lap is the same list again. The chain's own key is not in `ordered`, so
    /// from it the list reads as it is. A state written before the list was
    /// kept, or a key in hand that is not one of them, answers the list
    /// unchanged.
    func ring(from current: ComposerModelSelection?) -> [ComposerModelSelection] {
        guard let ordered, !ordered.isEmpty else { return remaining }
        return ModelCandidates.circular(ordered, from: current)
    }

    /// Whether this walk has no list of its own to read: the reader moved the
    /// conversation to another model after the failure, and the list built for
    /// the model that failed no longer says what to send. `canAskAgain` counts
    /// it, so that failure keeps a Retry on the bar, and the send builds the
    /// list again from the model now in hand (`ChatRuntime.sendNextModel`)
    /// rather than from the one the walk belonged to.
    var needsFreshWalk: Bool {
        ordered == nil && remaining.isEmpty && kind != nil && !text.isEmpty
    }

    /// Whether the reader's own Retry has anything to send: a candidate left
    /// in this walk, the walk's list to go round again (`lap(from:)`), or —
    /// after a move to another model — a list still to be built for it. What
    /// keeps that retry on the model bar once the walk is spent, rather than
    /// leaving the conversation on the key that failed.
    func canAskAgain(from current: ComposerModelSelection?) -> Bool {
        nextCandidate(readerAsked: true) != nil || !ring(from: current).isEmpty || needsFreshWalk
    }

    /// Seats the walk at the key now in hand, so its next candidate is the one
    /// after that key in the list's order — never where the key before it had
    /// got to. What the reader's own switch to another key calls: that key is
    /// the first this walk offers, since it is the one they chose to send on,
    /// while a key that already failed in this walk stays failed.
    mutating func reseat(from current: ComposerModelSelection?) {
        guard let ordered, !ordered.isEmpty else { return }
        remaining = ring(from: current)
    }

    /// Goes round the list again, from the key in hand: the next lap is the
    /// walk's own list read on from where it stopped, the key in hand coming
    /// back last, and every key tried again — a lap is the reader asking for
    /// the same keys once more, so what failed a lap ago is not what keeps
    /// them from being sent. What the reader's own Retry calls once the walk
    /// has nothing left: without it the conversation would be stranded on the
    /// key that failed, with no way back to a key the walk left behind.
    mutating func lap(from current: ComposerModelSelection?) {
        guard let ordered, !ordered.isEmpty else { return }
        var list = ring(from: current)
        // The key in hand is the one whose failure is being answered: the lap
        // starts after it and comes back to it, so a key that just failed is
        // never the first thing sent again.
        if let first = list.first, first.retryKey == current?.retryKey {
            list.append(list.removeFirst())
        }
        remaining = list
        triedKeys = []
    }
}

enum ModelCandidates {
    /// `list` read as a ring whose first place is `current`: that one, then
    /// the ones after it, then the ones before it and round again. The order
    /// itself is the list's own — this only moves where reading it starts, so
    /// a walk down the list wraps back to its top instead of jumping there.
    /// Unchanged when `current` is not one of them. `key` says what makes two
    /// elements the same place.
    static func circular<T>(_ list: [T], from current: T?, key: (T) -> String) -> [T] {
        guard let current, let place = list.firstIndex(where: { key($0) == key(current) }) else {
            return list
        }
        return Array(list[place...]) + Array(list[..<place])
    }

    /// The keys of one Base URL as that ring (`ModelKeys.serving`), where a
    /// place is the configuration itself.
    static func circular(_ keys: [AgentAccount], from current: AgentAccount?) -> [AgentAccount] {
        circular(keys, from: current, key: { $0.id })
    }

    /// The same ring over a walk's own list, where a place is the key and the
    /// model (`retryKey`): two selections that differ only in effort or speed
    /// are the same place.
    static func circular(
        _ list: [ComposerModelSelection],
        from current: ComposerModelSelection?,
    ) -> [ComposerModelSelection] {
        circular(list, from: current, key: { $0.retryKey })
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
