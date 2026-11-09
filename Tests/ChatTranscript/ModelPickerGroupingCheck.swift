import ApelinProtocol
import Foundation

/// The model picker's first page groups the enabled configurations by the
/// Base URL their requests go to: two spellings of one address are one group,
/// two addresses on one host are two, and a configuration that names no Base
/// URL stands alone. A group of several is named after its Base URL, one of
/// one after its own name. Provider families no longer decide the groups.
func checkModelPickerGrouping() {
    func account(_ provider: AgentProvider, baseURL: String?, name: String? = nil) -> AgentAccount {
        AgentAccount(
            provider: provider,
            id: provider.rawValue,
            method: .apiKey,
            signedIn: true,
            name: name,
            baseURL: baseURL
        )
    }

    func groups(_ accounts: [AgentAccount]) -> [ModelPickerGrouping.Group] {
        ModelPickerGrouping.groups(of: accounts) { $0.name ?? $0.provider.rawValue }
    }

    // One address in two spellings is one group, named after the address.
    let sameURL = groups([
        account(.openAICompatible, baseURL: "https://relay.example/v1/"),
        account(.deepSeek, baseURL: "relay.example/v1"),
    ])
    precondition(sameURL.count == 1, "\(sameURL.map(\.indices))")
    precondition(sameURL[0].indices == [0, 1], "\(sameURL[0].indices)")
    precondition(sameURL[0].title == "relay.example/v1", sameURL[0].title)
    precondition(sameURL[0].provider == .openAICompatible, "the first configuration marks the group")

    // A request path pasted as the Base URL is not another endpoint.
    let pasted = groups([
        account(.openAICompatible, baseURL: "https://relay.example/v1/models"),
        account(.openAICompatible, baseURL: "https://relay.example/v1"),
    ])
    precondition(pasted.count == 1 && pasted[0].title == "relay.example/v1", "\(pasted.map(\.indices))")

    // Two addresses on one host are two groups, one per Base URL.
    let twoPaths = groups([
        account(.openAICompatible, baseURL: "https://relay.example/v1"),
        account(.openAICompatible, baseURL: "https://relay.example/v2"),
    ])
    precondition(twoPaths.map(\.indices) == [[0], [1]], "\(twoPaths.map(\.indices))")
    precondition(twoPaths.map(\.title) == ["relay.example/v1", "relay.example/v2"], "\(twoPaths.map(\.title))")

    // An http and an https address are two endpoints.
    let twoSchemes = groups([
        account(.openAICompatible, baseURL: "http://relay.example/v1"),
        account(.openAICompatible, baseURL: "https://relay.example/v1"),
    ])
    precondition(twoSchemes.count == 2, "scheme tells the endpoints apart")

    // A configuration with no Base URL stands alone, one per account, and
    // keeps its own name.
    let noURL = groups([
        account(.anthropic, baseURL: nil, name: "Work"),
        account(.anthropicOAuth, baseURL: nil),
    ])
    precondition(noURL.map(\.indices) == [[0], [1]], "\(noURL.map(\.indices))")
    precondition(noURL.map(\.title) == ["Work", "anthropic-oauth"], "\(noURL.map(\.title))")

    // The same address groups whatever provider family wrote the keys, and a
    // group of several is named after the address, not a family.
    let mixedProviders = groups([
        account(.openAICompatible, baseURL: "https://relay.example/v1", name: "Relay"),
        account(.openAICompatible, baseURL: "https://relay.example/v1"),
        account(.anthropic, baseURL: "https://relay.example/v1", name: "Relay 2"),
    ])
    precondition(mixedProviders.count == 1 && mixedProviders[0].indices == [0, 1, 2], "\(mixedProviders.map(\.indices))")
    precondition(mixedProviders[0].title == "relay.example/v1", mixedProviders[0].title)

    // Groups keep the order their first configuration appears in, and every
    // configuration appears exactly once.
    let ordered = groups([
        account(.openAICompatible, baseURL: "https://b.example/v1"),
        account(.anthropic, baseURL: "https://a.example/v1"),
        account(.deepSeek, baseURL: "https://b.example/v1"),
        account(.openAICompatible, baseURL: nil),
    ])
    precondition(ordered.map(\.indices) == [[0, 2], [1], [3]], "\(ordered.map(\.indices))")
    precondition(ordered.flatMap(\.indices) == [0, 1, 2, 3], "every configuration exactly once")
    precondition(ordered[0].provider == .openAICompatible && ordered[0].title == "b.example/v1", "\(ordered[0].title)")

    print("ok: the model picker groups configurations by Base URL, one per address and first-seen order")
}
