import ApelinProtocol
import Foundation

/// One Base URL's keys, the model each of them serves, and the name each is
/// offered under: the list the composer's key control, the picker's key page
/// and a fallback all read, in one order, never naming a secret.
func checkModelKeys() {
    let relay = "https://relay.example/v1"
    let other = "https://other.example/v1"
    let third = "https://third.example/v1"

    /// A saved configuration with `models` enabled for it. A provider the
    /// reader adds endpoints to keeps one list per Base URL, every other one
    /// per configuration, so this writes the list exactly as Settings does.
    func account(
        _ provider: AgentProvider,
        _ id: String,
        _ baseURL: String?,
        name: String? = nil,
        models: [String] = [],
        signedIn: Bool = true,
    ) -> AgentAccount {
        let account = AgentAccount(
            provider: provider,
            id: id,
            method: .apiKey,
            signedIn: signedIn,
            name: name,
            account: "relay.example",
            baseURL: baseURL,
            models: models,
            usesAPIKey: true,
        )
        guard !models.isEmpty else { return account }
        EnabledModels.save(Set(models), custom: [], hidden: [], for: account)
        return account
    }

    /// What the app's `AgentAccount.title` resolves to, without the interface.
    func title(_ account: AgentAccount) -> String {
        account.name ?? account.provider.rawValue
    }

    // Two API keys at one address are two keys of one Base URL; another
    // address keeps its own models.
    let a = account(.openAICompatible, "openai-compatible.a", relay, models: ["m"])
    let b = account(.openAICompatible, "openai-compatible.b", relay, models: ["m"])
    let c = account(.openAICompatible, "openai-compatible.c", other, models: ["n"])

    let atRelay = ModelKeys.serving("m", at: relay, from: [a, b, c])
    precondition(atRelay.map(\.id) == [a.id, b.id], "both keys of the address, in the listing's order: \(atRelay.map(\.id))")
    precondition(ModelKeys.serving("n", at: relay, from: [a, b, c]).isEmpty, "a model no key of this address serves")
    precondition(ModelKeys.serving("n", at: other, from: [a, b, c]).map(\.id) == [c.id], "the other address's own list")
    precondition(ModelKeys.serving("m", at: nil, from: [a, b, c]).isEmpty, "a selection that names no address offers none")

    // A key that is not signed in is offered to nobody.
    let signedOut = account(.openAICompatible, "openai-compatible.d", relay, models: ["m"], signedIn: false)
    precondition(ModelKeys.serving("m", at: relay, from: [a, b, signedOut]).map(\.id) == [a.id, b.id], "a signed-out key")
    precondition(ModelKeys.enabled([a, signedOut, b]).map(\.id) == [a.id, b.id], "the enabled keys, in order")

    // A provider that keeps one sign-in per key keeps one model list per key:
    // two of them on one address may serve different models, and only the key
    // that serves one is offered for it. Nothing assumes an address's keys
    // share a list.
    let one = account(.deepSeek, "deepseek-a", relay, models: ["m"])
    let two = account(.deepSeek, "deepseek-b", relay, models: ["n"])
    precondition(ModelKeys.serving("m", at: relay, from: [one, two]).map(\.id) == [one.id], "only the key that serves it")
    precondition(ModelKeys.serving("n", at: relay, from: [one, two]).map(\.id) == [two.id], "and the other for its own")
    // The address, not the family, decides the tree: another brand at the same
    // address is one of its keys.
    precondition(
        ModelKeys.serving("m", at: relay, from: [a, one, b]).map(\.id) == [a.id, one.id, b.id],
        "the reader's order is kept, whatever wrote the keys",
    )

    // One key alone keeps its configuration's name.
    precondition(ModelKeys.labels([a], title: title) == [title(a)], "\(ModelKeys.labels([a], title: title))")

    // Several keys of one name are told apart by their place in the list:
    // `Relay - API Key A`, `Relay - API Key B`.
    let named = (0 ..< 3).map { account(.openAICompatible, "labelled-\($0)", third, name: "Relay", models: ["m"]) }
    let labels = ModelKeys.labels(named, title: title)
    precondition(labels == ["Relay - API Key A", "Relay - API Key B", "Relay - API Key C"], "\(labels)")
    for label in labels {
        precondition(!label.contains("relay.example") && !label.contains("labelled-"), "a name, never a secret: \(label)")
    }

    // Past the alphabet the place itself, so a long list is still told apart.
    let many = (0 ..< 27).map { account(.openAICompatible, "many-\($0)", third, name: "Relay", models: ["m"]) }
    let manyLabels = ModelKeys.labels(many, title: title)
    precondition(manyLabels.count == 27, "one name per row")
    precondition(manyLabels.last == "Relay - API Key 27", "\(manyLabels.last ?? "")")
    precondition(Set(manyLabels).count == 27, "every row told apart")

    // The control spends the letter only where two names would read alike:
    // beside the list, and alone, the configuration's own name is enough.
    precondition(
        ModelKeys.controlName(for: named[1], among: named, title: title) == "Relay - API Key B",
        "\(ModelKeys.controlName(for: named[1], among: named, title: title))",
    )
    let distinct = [
        account(.openAICompatible, "distinct-0", third, name: "Work", models: ["m"]),
        account(.openAICompatible, "distinct-1", third, name: "Home", models: ["m"]),
    ]
    precondition(ModelKeys.controlName(for: distinct[0], among: distinct, title: title) == "Work", "two names that differ need no letter")
    precondition(ModelKeys.controlName(for: named[0], among: [named[0]], title: title) == "Relay", "a key offered alone keeps its name")
    precondition(ModelKeys.controlName(for: named[0], among: [], title: title) == "Relay", "a key the list does not hold keeps its name")

    // The letter is the place in the list the control is showing, and the list
    // of names is built the same way: the row and the control agree.
    let reversed = [named[1], named[0], named[2]]
    precondition(
        ModelKeys.controlName(for: named[0], among: reversed, title: title) == "Relay - API Key B",
        "\(ModelKeys.controlName(for: named[0], among: reversed, title: title))",
    )
    precondition(
        ModelKeys.labels(reversed, title: title)[1] == ModelKeys.controlName(for: named[0], among: reversed, title: title),
        "the row and the control name the same key the same way",
    )

    print("ok: one Base URL's keys are listed, named and offered in one order, never by a secret")
}
