import Foundation

/// One API call a page made with `fetch` or `XMLHttpRequest`, as the page's own
/// script reported it, completed with the `Cookie` header this browser would
/// send to it.
///
/// Kept so the same API can be called again from outside the page — with the
/// headers and the cookies it sent — instead of driving the site's interface.
/// Written to `captures/calls.ndjson` under the app's data folder, one JSON
/// object a line.
struct WebAPICall: Codable, Equatable, Identifiable, Sendable {
    /// How the page made the call.
    enum Kind: String, Codable, Sendable {
        case fetch
        case xhr
    }

    /// What is kept of what a page reports. A page can post to the handler
    /// itself, so every field is cut to its own limit here.
    enum Limit {
        static let method = 16
        static let url = 8192
        static let page = 8192
        static let headerName = 128
        static let headerValue = 2048
        static let headerCount = 64
        static let body = 262_144
        static let response = 262_144
        static let message = 2048
    }

    let id: String
    let kind: Kind
    let at: Date
    let method: String
    let url: String
    /// The address of the page that made the call.
    let page: String
    let status: Int?
    let error: String?
    let durationMilliseconds: Int?
    let requestHeaders: [String: String]
    let requestBody: String?
    /// The `Cookie` header this browser would send to `url`, which a page's own
    /// script cannot read when the site keeps a cookie HttpOnly. Filled in by
    /// the browser, never by the page.
    var cookies: String?
    /// The client name this browser sends a site, which a page's own script
    /// cannot read either. Filled in by the browser, so a call made here in the
    /// app goes out as the page's own did. Absent in a call recorded before it
    /// was written down.
    var userAgent: String?
    let response: String?

    /// From what the page's script posted; nil when it holds no call.
    init?(payload: [String: Any]) {
        guard let kind = (payload["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let method = (payload["method"] as? String)?.uppercased(),
              let rawURL = payload["url"] as? String, !rawURL.isEmpty
        else { return nil }
        let milliseconds = (payload["at"] as? NSNumber)?.doubleValue
            ?? Date().timeIntervalSince1970 * 1000
        id = UUID().uuidString
        self.kind = kind
        at = Date(timeIntervalSince1970: milliseconds / 1000)
        self.method = String(method.prefix(Limit.method))
        url = String(rawURL.prefix(Limit.url))
        page = String(((payload["page"] as? String) ?? "").prefix(Limit.page))
        status = (payload["status"] as? NSNumber)?.intValue
        error = Self.cut(payload["error"], to: Limit.message)
        durationMilliseconds = (payload["durationMilliseconds"] as? NSNumber)?.intValue
        requestHeaders = Self.headers(payload["headers"])
        requestBody = Self.cut(payload["body"], to: Limit.body)
        cookies = nil
        response = Self.cut(payload["response"], to: Limit.response)
    }

    /// The same call with the cookies this browser would send to it.
    func withCookies(_ header: String?) -> WebAPICall {
        var copy = self
        copy.cookies = header
        return copy
    }

    /// The same call with the client name this browser sends a site.
    func withUserAgent(_ agent: String?) -> WebAPICall {
        guard let agent, !agent.isEmpty else { return self }
        var copy = self
        copy.userAgent = agent
        return copy
    }

    /// The host the call went to, which is what a row leads with.
    var host: String {
        URL(string: url)?.host ?? url
    }

    /// The path and the query, which tell two calls to one host apart.
    var path: String {
        guard let parsed = URL(string: url) else { return url }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        guard let query = parsed.query, !query.isEmpty else { return path }
        return path + "?" + query
    }

    /// The status it answered with, when it answered.
    var statusText: String? {
        status.map(String.init)
    }

    /// How long it took, in the unit that reads best.
    var durationText: String? {
        guard let durationMilliseconds, durationMilliseconds >= 0 else { return nil }
        return Self.durationText(durationMilliseconds)
    }

    /// How long `milliseconds` took, in the unit that reads best.
    static func durationText(_ milliseconds: Int) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        let seconds = (Double(milliseconds) / 100).rounded() / 10
        return "\(seconds) s"
    }

    /// The headers in the order they are shown.
    var sortedRequestHeaders: [(name: String, value: String)] {
        requestHeaders
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { (name: $0.key, value: $0.value) }
    }

    /// The `Cookie` header as one pair a row.
    var cookiePairs: [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = []
        guard let cookies else { return pairs }
        for piece in cookies.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
            guard !name.isEmpty else { continue }
            pairs.append((name, String(trimmed[trimmed.index(after: separator)...])))
        }
        return pairs
    }

    /// The call as a `curl` command, cookies and all, so it can be run again
    /// from a shell: what a site's own interface did, done directly.
    var curlCommand: String {
        var parts = ["curl -X \(method)", Self.quoted(url)]
        for header in sortedRequestHeaders {
            parts.append("-H \(Self.quoted("\(header.name): \(header.value)"))")
        }
        if let cookies, !cookies.isEmpty {
            parts.append("-H \(Self.quoted("Cookie: \(cookies)"))")
        }
        if let requestBody, !requestBody.isEmpty {
            parts.append("--data-raw \(Self.quoted(requestBody))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// `value` between single quotes, with an embedded one escaped the way a
    /// POSIX shell reads it.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// How much of a `curl` command the link to a chat can carry, with room
    /// for the line above it and the note below it.
    static let handoffLimit = 30000

    /// What a chat receives so Apelin makes this call itself, instead of the
    /// site's pages being driven again: the instruction, then the whole call
    /// as a `curl` command, cookies and all.
    ///
    /// Cut when the call is longer than a chat link can carry; the whole of it
    /// stays on the screen that shows the call.
    var handoffPrompt: String {
        let instruction = String(localized: "Call this API directly, without the site's pages, and tell me what it answers:")
        let call = curlCommand.utf8.count > Self.handoffLimit
            ? Self.cutToBytes(curlCommand, Self.handoffLimit)
                + "\n\n" + String(localized: "This call is longer than a chat can carry, so its end is left out. Copy it whole from the call's own screen.")
            : curlCommand
        return Self.promptSafe(instruction + "\n\n" + call)
    }

    /// `text` without the control characters a chat link cannot carry. A
    /// request body can hold one, and a link holding one opens no chat at all:
    /// dropped here, so the call still reaches the chat rather than being lost
    /// whole. A line break and a tab stay, and the untouched call stays on the
    /// screen that shows it.
    static func promptSafe(_ text: String) -> String {
        let allowed: [Unicode.Scalar] = ["\n", "\r", "\t"]
        guard text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !allowed.contains($0)
        }) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || allowed.contains($0)
        }))
    }

    /// `text` cut to `limit` UTF-8 bytes, never in the middle of a character.
    static func cutToBytes(_ text: String, _ limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var data = Data(text.utf8.prefix(limit))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cut(_ value: Any?, to limit: Int) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    private static func headers(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any], !raw.isEmpty else { return [:] }
        var headers: [String: String] = [:]
        for (name, value) in raw.prefix(Limit.headerCount) {
            let text = (value as? String) ?? String(describing: value)
            headers[String(name.prefix(Limit.headerName))] = String(text.prefix(Limit.headerValue))
        }
        return headers
    }
}
