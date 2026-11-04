import Foundation

/// One Base URL, named the way a key is told apart without a secret.
///
/// Two keys that name the same address in different spellings are one
/// endpoint: `https://relay.example/v1/` and `relay.example/v1` reach the same
/// server, and so do `https://relay.example/v1/models` and
/// `https://relay.example/v1` — what a reader pasted from a provider's page is
/// the endpoint of the key, not a request path. Two *different* addresses on
/// one host (`/v1` and `/v2`, or an `http` and an `https` one) are two
/// endpoints, because the models behind them are not the same list.
///
/// This is the same rule the worker normalises its own request address with
/// (`ProviderModels.normalizedBase`), plus the case folding a host name gets
/// for free: a name is compared with scheme and host lowercased, while the
/// path keeps its case, which is what the server sees.
public enum AgentEndpoint {
    /// The canonical form of a Base URL, or nil when what was given cannot be
    /// an address (empty, or no host at all).
    public static func canonical(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        for suffix in ["/chat/completions", "/completions", "/models", "/messages"] {
            while text.lowercased().hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
        }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = components.scheme?.lowercased() ?? "https"
        components.host = host.lowercased()
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString
    }

    /// What a group of keys pointing at one Base URL is called: the address
    /// without the scheme it shares with every other one, so a section title
    /// stays readable.
    public static func title(_ canonical: String) -> String {
        var text = canonical
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
            break
        }
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
