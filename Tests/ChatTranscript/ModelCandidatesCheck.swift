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

    // Switching keys goes round the list as a ring whose place is the key in
    // hand: from it the walk takes the key after it, on to the last, and wraps
    // back to the top. The key in hand is remembered, so a second switch on the
    // same Base URL reaches the third key — it does not start over at the
    // first one as a walk that only ever dropped the current key would.
    let ringA = account(.openAICompatible, "ring-a", "https://ring.example/v1", ["m"])
    let ringB = account(.openAICompatible, "ring-b", "https://ring.example/v1", ["m"])
    let ringC = account(.openAICompatible, "ring-c", "https://ring.example/v1", ["m"])
    let ring = [ringA, ringB, ringC]
    func ringOrder(_ from: AgentAccount) -> [String] {
        keys(ModelCandidates.fallbackList(current: selection(from, "m"), accounts: ring))
    }
    precondition(ringOrder(ringA) == ["ring-b|m", "ring-c|m"], "\(ringOrder(ringA))")
    precondition(ringOrder(ringB) == ["ring-c|m", "ring-a|m"], "\(ringOrder(ringB))")
    precondition(ringOrder(ringC) == ["ring-a|m", "ring-b|m"], "\(ringOrder(ringC))")

    // Reading the ring from a key only chooses where reading starts: the list's
    // own order is kept, and a key outside it changes nothing.
    let ringList = ModelKeys.serving("m", at: ringA.endpoint, from: ring)
    precondition(
        ModelCandidates.circular(ringList, from: ringB).map(\.id) == ["ring-b", "ring-c", "ring-a"],
        "\(ModelCandidates.circular(ringList, from: ringB).map(\.id))",
    )
    precondition(ModelCandidates.circular(ringList, from: nil).map(\.id) == ["ring-a", "ring-b", "ring-c"], "no key in hand")
    precondition(ModelCandidates.circular(ringList, from: first).map(\.id) == ["ring-a", "ring-b", "ring-c"], "another list's key")

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

    // When every candidate of a walk has been tried the walk is not over: its
    // own list is still there to go round again, which is what keeps the
    // reader's Retry on the bar instead of stranding the conversation on the
    // key that failed.
    let firstSelection = ModelCandidate(account: first, model: "m").selection
    var spent = ModelRetryState(
        remaining: [],
        ordered: [spareSelection, farSelection, firstSelection],
        triedKeys: [spareSelection.retryKey, farSelection.retryKey],
        text: "hello",
    )
    precondition(spent.canAskAgain(from: farSelection), "a spent walk still has its list to go round")
    spent.lap(from: farSelection)
    precondition(
        spent.remaining.map(\.retryKey) == [firstSelection.retryKey, spareSelection.retryKey, farSelection.retryKey],
        "the lap reads on from the key in hand and comes back to it last: \(spent.remaining.map(\.retryKey))",
    )
    precondition(spent.triedKeys.isEmpty, "a lap tries every key again")
    precondition(spent.nextCandidate(readerAsked: true, now: now)?.retryKey == firstSelection.retryKey, "starting with the key after the one in hand")
    precondition(spent.canAskAgain(from: farSelection), "and the walk is still a ring")

    // One key alone: the reader's Retry has that key to send again rather than
    // nothing at all, so the walk does not vanish on its first failure.
    var alone = ModelRetryState(remaining: [], ordered: [farSelection], triedKeys: [farSelection.retryKey], text: "hi")
    precondition(alone.canAskAgain(from: farSelection), "one key alone still has the reader's retry")
    alone.lap(from: farSelection)
    precondition(alone.remaining.map(\.retryKey) == [farSelection.retryKey], "and the lap is that key")
    // With no list to go round at all there is nothing to ask for.
    let nothing = ModelRetryState(remaining: [], ordered: [], triedKeys: [], text: "")
    precondition(!nothing.canAskAgain(from: spareSelection), "no list and nothing left is no retry")

    // The reader's own switch seats the walk at the key they chose: that key is
    // the first this walk offers, and the one after it is next, rather than
    // where the key in hand had left off. What already failed stays failed.
    var switched = ModelRetryState(
        remaining: [],
        ordered: [spareSelection, farSelection, firstSelection],
        triedKeys: [spareSelection.retryKey],
        text: "hello",
    )
    switched.reseat(from: farSelection)
    precondition(
        switched.remaining.map(\.retryKey) == [farSelection.retryKey, firstSelection.retryKey, spareSelection.retryKey],
        "a switch seats the walk at the key in hand: \(switched.remaining.map(\.retryKey))",
    )
    precondition(switched.nextCandidate(readerAsked: true, now: now)?.retryKey == farSelection.retryKey, "the key just chosen is offered first")
    precondition(switched.triedKeys == [spareSelection.retryKey], "and what already failed stays failed")
    // A state written before the list was kept has no ring to go round, and
    // behaves as it always did: what is left of `remaining`, and nothing else.
    var old = ModelRetryState(remaining: [], text: "hello")
    precondition(!old.canAskAgain(from: spareSelection), "an old state has no list to go round")
    old.remaining = [farSelection]
    precondition(old.canAskAgain(from: spareSelection), "and keeps its candidates")

    // The reader moving the conversation to another model empties the walk: the
    // list built for the model that failed no longer says what to send. The
    // failure keeps its Retry, and the send builds the list again from the
    // model now in hand — so a walk with nothing left and no list is one to
    // build, not one that is over.
    var moved = ModelRetryState(remaining: [], text: "hello", kind: .spentAllowance)
    precondition(moved.needsFreshWalk, "a walk emptied by a move to another model is one to build again")
    precondition(moved.canAskAgain(from: spareSelection), "so the failure keeps its Retry")
    precondition(moved.nextCandidate(readerAsked: true, now: now) == nil, "with nothing to send until it is built")
    moved.remaining = [farSelection]
    moved.ordered = [farSelection]
    precondition(!moved.needsFreshWalk && moved.canAskAgain(from: spareSelection), "and once built it is a walk like any other")
    // A state with no failure kind holds no Retry, so there is nothing to build
    // for it: that walk is over, as it was before the list was kept.
    let kindless = ModelRetryState(remaining: [], text: "hello")
    precondition(!kindless.needsFreshWalk && !kindless.canAskAgain(from: spareSelection), "a walk with no failure kind is over")

    print("ok: a failed run falls back key by key for the same model, another model only on the reader's say-so")
}
