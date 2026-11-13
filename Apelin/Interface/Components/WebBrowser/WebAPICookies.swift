import Foundation

/// The `Cookie` header a browser would send to a URL, built from its cookie
/// store: the part of a logged-in call a page's own script cannot read, since a
/// site's session cookie is usually HttpOnly.
enum WebAPICookies {
    /// One `name=value; name=value` line, the longest matching path first, as a
    /// browser sorts what it sends. Nil when nothing matches.
    static func header(for url: URL, cookies: [HTTPCookie]) -> String? {
        let matching = cookies
            .filter { matches($0, url: url) }
            .sorted { $0.path.count > $1.path.count }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Whether a cookie is sent with a request to `url`: its domain covers the
    /// host, its path prefixes the URL's, and a secure one needs https.
    static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let domain = cookie.domain.lowercased().hasPrefix(".")
            ? String(cookie.domain.lowercased().dropFirst())
            : cookie.domain.lowercased()
        guard !domain.isEmpty, host == domain || host.hasSuffix("." + domain) else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path.hasPrefix(cookiePath)
    }
}
