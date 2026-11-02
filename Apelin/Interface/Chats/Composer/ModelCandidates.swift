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

enum ModelCandidates {
    /// Builds the fallback order starting after `current`. `current` itself is
    /// excluded; if nothing else is available the list is empty (caller keeps
    /// the current selection). Accounts must already be filtered to signed-in,
    /// enabled ones (see `EnabledModels.accounts(from:)`).
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

        // 1. Same provider family, same model, other configurations.
        for account in enabled where account.provider.modelFamily == current.provider.modelFamily {
            if account.provider == current.provider && account.profileID == current.profileID { continue }
            if (account.models ?? []).contains(current.model) {
                add(ModelCandidate(account: account, model: current.model))
            }
        }
        // 2. Same provider family, other models.
        for account in enabled where account.provider.modelFamily == current.provider.modelFamily {
            if account.provider == current.provider && account.profileID == current.profileID { continue }
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        // 3. Other providers offering the same model name.
        for account in enabled where account.provider.modelFamily != current.provider.modelFamily {
            if (account.models ?? []).contains(current.model) {
                add(ModelCandidate(account: account, model: current.model))
            }
        }
        // 4. The rest.
        for account in enabled where account.provider.modelFamily != current.provider.modelFamily {
            for model in (account.models ?? []) where model != current.model {
                add(ModelCandidate(account: account, model: model))
            }
        }
        return result
    }
}
