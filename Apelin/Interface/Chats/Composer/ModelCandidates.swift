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
    /// Builds the fallback order starting after `current`. `current` itself is
    /// excluded; if nothing else is available the list is empty (caller keeps
    /// the current selection). Accounts must already be filtered to signed-in,
    /// enabled ones (see `EnabledModels.accounts(from:)`).
    ///
    /// Another key on the *same Base URL*, with the same model, comes first:
    /// that is what a spent allowance or a refused key needs, and it is the
    /// one swap that costs the conversation nothing. Then the same model on
    /// the provider's family, then that model name on any other provider, and
    /// only after all of those the reader's other enabled models — always the
    /// same model before a different one.
    static func fallbackList(
        current: ComposerModelSelection?,
        accounts: [AgentAccount],
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

        // 1. The same model on another key of the same Base URL.
        let currentAccount = enabled.first(where: isCurrent)
            ?? enabled.first(where: { $0.provider == current.provider && offers($0, current.model) })
        if let endpoint = currentAccount?.endpoint {
            for account in enabled
                where account.endpoint == endpoint && !isCurrent(account) && offers(account, current.model)
            {
                add(ModelCandidate(account: account, model: current.model))
            }
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
        // first.
        for account in enabled
            where !isCurrent(account) && account.provider.modelFamily == current.provider.modelFamily
        {
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        // 5. The rest.
        for account in enabled where account.provider.modelFamily != current.provider.modelFamily {
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        return result
    }
}
