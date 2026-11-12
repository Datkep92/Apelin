import ApelinProtocol
import Foundation

/// The order a failed run falls back through: another key for the same model
/// on the same Base URL first, then that model on the provider's family, then
/// anywhere else — and another model only where the reader turned the switch
/// on. Plus the cooldown a candidate that failed is stepped over by.
func checkModelCandidates() {
    let relay = "https://relay.example/v1"
    let other = "https://other.example/v1"
    let qoder = "https://qoder.example/v1"

    func account(
        _ provider: AgentProvider,
        _ id: String,
        _ baseURL: String?,
        _ models: [String],
        signedIn: Bool = true,
    ) -> AgentAccount {
        let account = AgentAccount(
            provider: provider,
            id: id,
            method: .apiKey,
            signedIn: signedIn,
            name: nil,
            account: "relay.example",
            baseURL: baseURL,
            models: models,
            usesAPIKey: true,
        )
        EnabledModels.save(Set(models), custom: [], hidden: [], for: account)
        return account
    }

    func selection(_ account: AgentAccount, _ model: String) -> ComposerModelSelection {
        ComposerModelSelection(
            provider: account.provider,
            model: model,
            profileID: account.profileID,
            supportedEfforts: [],
            supportedTiers: [],
        )
    }

    func keys(_ list: [ModelCandidate]) -> [String] {
        list.map { "\($0.account.id)|\($0.model)" }
    }

    // One address with two keys — the one in hand and the spare — another
    // address of the same provider serving the model and another one, the same
    // brand under another regional site, and a different brand.
    let first = account(.openAICompatible, "cand-a", relay, ["m"])
    let spare = account(.openAICompatible, "cand-b", relay, ["m"])
    let farAway = account(.openAICompatible, "cand-c", other, ["m", "n"])
    let regional = account(.qoderCN, "cand-qcn", qoder, ["m"])
    let sibling = account(.qoder, "cand-q", qoder, ["m"])
    let stranger = account(.deepSeek, "cand-d", "https://deepseek.example/v1", ["m", "n"])
    let accounts = [first, spare, farAway, regional, sibling, stranger]

    // The same model, every key for it: the one on the Base URL in hand first,
    // then the provider's family, then any other brand. No other model.
    let sameModel = ModelCandidates.fallbackList(current: selection(first, "m"), accounts: accounts)
    precondition(
        keys(sameModel) == ["cand-b|m", "cand-c|m", "cand-qcn|m", "cand-q|m", "cand-d|m"],
        "\(keys(sameModel))",
    )
    precondition(sameModel.allSatisfy { $0.model == "m" }, "another model only on the reader's say-so")

    // The brand's other regional site counts as the family, so its key comes
    // before another brand's — and the key in hand is never offered back.
    let fromRegional = ModelCandidates.fallbackList(current: selection(regional, "m"), accounts: accounts)
    precondition(keys(fromRegional) == ["cand-q|m", "cand-a|m", "cand-b|m", "cand-c|m", "cand-d|m"], "\(keys(fromRegional))")
    let fromSibling = ModelCandidates.fallbackList(current: selection(sibling, "m"), accounts: accounts)
    precondition(keys(fromSibling) == ["cand-qcn|m", "cand-a|m", "cand-b|m", "cand-c|m", "cand-d|m"], "\(keys(fromSibling))")

    // With the reader's switch on, another model comes last, the provider's
    // family before any other brand, and every key for the model in hand
    // before either.
    let otherModels = ModelCandidates.fallbackList(current: selection(first, "m"), accounts: accounts, otherModels: true)
    precondition(
        keys(otherModels) == ["cand-b|m", "cand-c|m", "cand-qcn|m", "cand-q|m", "cand-d|m", "cand-c|n", "cand-d|n"],
        "\(keys(otherModels))",
    )

    // No key in hand: every enabled key, once per model it serves.
    let all = ModelCandidates.fallbackList(current: nil, accounts: accounts, otherModels: true)
    precondition(keys(all) == ["cand-a|m", "cand-b|m", "cand-c|m", "cand-c|n", "cand-qcn|m", "cand-q|m", "cand-d|m", "cand-d|n"], "\(keys(all))")

    // A key that is not offered is in no list, and one that is not signed in
    // never appears.
    let ghost = account(.anthropic, "cand-ghost", relay, ["m"], signedIn: false)
    let fromGhost = ModelCandidates.fallbackList(current: selection(ghost, "m"), accounts: accounts + [ghost])
    precondition(keys(fromGhost) == ["cand-a|m", "cand-b|m", "cand-c|m", "cand-qcn|m", "cand-q|m", "cand-d|m"], "\(keys(fromGhost))")

    // The reader's own switch, kept where Settings writes it.
    let wasOn = ModelFallback.triesOtherModels
    ModelFallback.triesOtherModels = true
    precondition(ModelFallback.triesOtherModels, "the switch is kept")
    ModelFallback.triesOtherModels = false
    precondition(!ModelFallback.triesOtherModels, "and turns off again")
    ModelFallback.triesOtherModels = wasOn

    // A cooldown is kept by the configuration and the model, never by the
    // reader's effort, and a candidate that failed is stepped over until it
    // runs out — unless the reader asked themselves.
    let spareSelection = ModelCandidate(account: spare, model: "m").selection
    let farSelection = ModelCandidate(account: farAway, model: "m").selection
    precondition(spareSelection.retryKey != farSelection.retryKey, "two keys are two")
    precondition(spareSelection.retryKey != ModelCandidate(account: spare, model: "n").selection.retryKey, "two models are two")
    var loud = spareSelection
    loud.supportedEfforts = [.low, .high, .max]
    precondition(loud.retryKey == spareSelection.retryKey, "effort and speed are not the cooldown's")

    var state = ModelRetryState(remaining: [spareSelection, farSelection], text: "")
    let now = Date()
    precondition(state.nextCandidate(readerAsked: false, now: now)?.retryKey == spareSelection.retryKey, "the next candidate is the first left")
    state.triedKeys.insert(spareSelection.retryKey)
    precondition(state.nextCandidate(readerAsked: false, now: now)?.retryKey == farSelection.retryKey, "a key that already failed is stepped over")
    state.cooldowns = [farSelection.retryKey: now.addingTimeInterval(60)]
    precondition(state.nextCandidate(readerAsked: false, now: now) == nil, "one still waiting its cooldown is stepped over too")
    precondition(state.nextCandidate(readerAsked: false, now: now.addingTimeInterval(120))?.retryKey == farSelection.retryKey, "until it runs out")
    precondition(state.nextCandidate(readerAsked: true, now: now)?.retryKey == farSelection.retryKey, "the reader's own retry takes it anyway")
    state.triedKeys.insert(farSelection.retryKey)
    precondition(state.nextCandidate(readerAsked: true, now: now.addingTimeInterval(120)) == nil, "but never a key that already failed")

    print("ok: a failed run falls back key by key for the same model, another model only on the reader's say-so")
}
