import ApelinProtocol

/// The groups the model picker's first page shows: the enabled configurations
/// grouped by the Base URL their requests go to — several keys at one address
/// (whatever provider family wrote them) are one group, two addresses on one
/// host are two, and a configuration that names no Base URL stands alone.
/// A group formed by an address is called by that address, unless it holds a
/// single configuration the reader gave its own name; a configuration with no
/// Base URL keeps its own title. Groups keep the order their first
/// configuration appears in.
///
/// This file is compiled by the transcript tests too, so it imports nothing
/// but ApelinProtocol: the app passes its own `AgentAccount.title` in.
enum ModelPickerGrouping {
    /// One group's rows: the account indices in it, the provider marking the
    /// row (the first configuration's), and the title the row and the page it
    /// opens show — the shared Base URL for a group of several, the
    /// configuration's own name for one alone.
    struct Group: Equatable {
        var indices: [Int]
        var provider: AgentProvider
        var title: String
    }

    /// The configurations grouped by their canonical Base URL
    /// (`AgentAccount.endpoint`), each group in first-seen order. `title`
    /// names one configuration when a group holds one.
    static func groups(of accounts: [AgentAccount], title: (AgentAccount) -> String) -> [Group] {
        var seen: [String] = []
        var map: [String: [Int]] = [:]
        for (index, account) in accounts.enumerated() {
            // A configuration without a Base URL gets a key of its own, so
            // two such configurations never group together.
            let key = account.endpoint ?? "no-base-url-\(index)"
            if !seen.contains(key) { seen.append(key) }
            map[key, default: []].append(index)
        }
        return seen.map { key in
            let indices = map[key]!
            let first = accounts[indices[0]]
            // A group formed by a Base URL is called by that address — one
            // key at the address or several — unless it holds a single
            // configuration the reader named itself. One with no Base URL
            // keeps its own title.
            let address = key.contains("://")
            let namedAlone = indices.count == 1 && first.name != nil
            return Group(
                indices: indices,
                provider: first.provider,
                title: address && !namedAlone ? AgentEndpoint.title(key) : title(first)
            )
        }
    }
}
