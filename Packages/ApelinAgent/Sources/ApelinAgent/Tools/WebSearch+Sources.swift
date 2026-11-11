import Foundation

/// The sources `apelin_web_search` reads beside GitHub, Hacker News and Reddit:
/// DuckDuckGo's HTML endpoint for the open web, the Stack Exchange API and
/// Wikipedia. Each answers its own heading, and a source that is down or
/// answers nothing costs its heading alone, never the search.
///
/// Reading a source is two steps on purpose: the fetch (what goes on the wire)
/// and the parse (`static func`s taking bytes) — the parse is what the harness
/// tests, with a page saved as a fixture, so a change to it is caught without
/// the network.
extension WebSearch {
    /// One result as a source read it, before it becomes a line.
    struct SearchHit: Hashable, Sendable {
        var title: String
        var url: String
        /// What follows the link: a snippet, a score, tags.
        var detail: String?
    }

    // MARK: Lines

    /// What a source's hits become, or nil when it has none to show.
    static func lines(_ hits: [SearchHit], limit: Int) -> String? {
        let rows = hits.prefix(limit).compactMap { hit -> String? in
            let title = plainText(hit.title)
            let link = hit.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !link.isEmpty else { return nil }
            // Brackets in a title would end the link's text early.
            let safeTitle = title
                .replacingOccurrences(of: "[", with: "(")
                .replacingOccurrences(of: "]", with: ")")
            let detail = hit.detail.map(plainText) ?? ""
            return detail.isEmpty ? "- [\(safeTitle)](\(link))" : "- [\(safeTitle)](\(link)): \(detail)"
        }
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    // MARK: DuckDuckGo

    static func duckDuckGoURL(query: String) -> URL? {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    func duckDuckGoResults(query: String, limit: Int) async -> String? {
        guard let url = Self.duckDuckGoURL(query: query) else { return nil }
        do {
            var request = URLRequest(url: url)
            // This one answers a page, not JSON.
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let (data, _) = try await session.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return Self.lines(Self.duckDuckGoHits(html: html, limit: limit), limit: limit)
        } catch {
            return nil
        }
    }

    /// The results in DuckDuckGo's HTML page: every `result__a` link names a
    /// result, and the `result__snippet` that follows it, before the next
    /// result, is what it says.
    static func duckDuckGoHits(html: String, limit: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        var current: SearchHit?
        for anchor in anchors(in: html) {
            if anchor.classes.contains("result__a") {
                if let finished = current {
                    hits.append(finished)
                    current = nil
                }
                if hits.count >= limit { break }
                current = SearchHit(title: anchor.text, url: destination(anchor.href), detail: nil)
            } else if anchor.classes.contains("result__snippet"), let hit = current, hit.detail == nil {
                current?.detail = anchor.text
            }
        }
        if hits.count < limit, let finished = current {
            hits.append(finished)
        }
        return hits.filter { !$0.url.isEmpty }
    }

    // MARK: Wikipedia

    static func wikipediaURL(query: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(limit)),
            URLQueryItem(name: "srprop", value: "snippet"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
        ]
        return components?.url
    }

    func wikipediaResults(query: String, limit: Int) async -> String? {
        guard let url = Self.wikipediaURL(query: query, limit: limit) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            return Self.lines(Self.wikipediaHits(json: data, limit: limit), limit: limit)
        } catch {
            return nil
        }
    }

    static func wikipediaHits(json: Data, limit: Int) -> [SearchHit] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["search"] as? [[String: Any]]
        else { return [] }
        return pages.prefix(limit).compactMap { page in
            guard let title = page["title"] as? String, let pageID = page["pageid"] as? Int else { return nil }
            return SearchHit(
                title: title,
                url: "https://en.wikipedia.org/?curid=\(pageID)",
                detail: (page["snippet"] as? String).map(plainText),
            )
        }
    }

    // MARK: Stack Exchange

    static func stackExchangeURL(query: String, limit: Int) -> URL? {
        var components = URLComponents(string: "https://api.stackexchange.com/2.3/search/advanced")
        components?.queryItems = [
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "site", value: "stackoverflow"),
            URLQueryItem(name: "pagesize", value: String(limit)),
            URLQueryItem(name: "filter", value: "default"),
        ]
        return components?.url
    }

    func stackExchangeResults(query: String, limit: Int) async -> String? {
        guard let url = Self.stackExchangeURL(query: query, limit: limit) else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            return Self.lines(Self.stackExchangeHits(json: data, limit: limit), limit: limit)
        } catch {
            return nil
        }
    }

    static func stackExchangeHits(json: Data, limit: Int) -> [SearchHit] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = root["items"] as? [[String: Any]]
        else { return [] }
        return items.prefix(limit).compactMap { item in
            guard let title = item["title"] as? String, let link = item["link"] as? String else { return nil }
            let score = item["score"] as? Int ?? 0
            let answered = item["is_answered"] as? Bool ?? false
            let tags = (item["tags"] as? [String] ?? []).prefix(5).joined(separator: ", ")
            var detail = answered ? "\(score) points, answered" : "\(score) points, no answer yet"
            if !tags.isEmpty { detail += " — \(tags)" }
            return SearchHit(title: title, url: link, detail: detail)
        }
    }
}

// MARK: - Reading a page's tags

extension WebSearch {
    /// One `<a …>text</a>` of a page, as much of it as is read.
    struct Anchor {
        var classes: Set<String>
        var href: String
        var text: String
    }

    /// Every anchor in `html`, in the order the page writes them.
    static func anchors(in html: String) -> [Anchor] {
        var result: [Anchor] = []
        var search = html.startIndex
        while let open = html.range(of: "<a ", range: search ..< html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: open.upperBound ..< html.endIndex),
                  let close = html.range(of: "</a>", range: tagEnd.upperBound ..< html.endIndex)
            else { break }
            let attributes = String(html[open.upperBound ..< tagEnd.lowerBound])
            let classes = Set(
                (attribute("class", in: attributes) ?? "")
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init),
            )
            result.append(Anchor(
                classes: classes,
                href: attribute("href", in: attributes) ?? "",
                text: plainText(String(html[tagEnd.upperBound ..< close.lowerBound])),
            ))
            search = close.upperBound
        }
        return result
    }

    /// The value of `name` in a tag's attributes, unescaped; nil without one.
    /// Only a whole attribute name counts, so `data-class` is not `class`.
    static func attribute(_ name: String, in attributes: String) -> String? {
        var search = attributes.startIndex
        while let found = attributes.range(of: name + "=", range: search ..< attributes.endIndex) {
            let startsAttribute = found.lowerBound == attributes.startIndex
                || attributes[attributes.index(before: found.lowerBound)].isWhitespace
            guard startsAttribute else {
                search = found.upperBound
                continue
            }
            let valueStart = found.upperBound
            guard valueStart < attributes.endIndex else { return nil }
            let first = attributes[valueStart]
            if first == "\"" || first == "'" {
                let after = attributes.index(after: valueStart)
                guard let end = attributes[after...].firstIndex(of: first) else { return nil }
                return decodeEntities(String(attributes[after ..< end]))
            }
            let end = attributes[valueStart...].firstIndex(where: \.isWhitespace) ?? attributes.endIndex
            return decodeEntities(String(attributes[valueStart ..< end]))
        }
        return nil
    }

    /// A page's text: no tags, its character references written out, runs of
    /// whitespace as one space.
    static func plainText(_ html: String) -> String {
        var text = ""
        var insideTag = false
        for character in html {
            if character == "<" {
                insideTag = true
                text.append(" ")
            } else if character == ">" {
                insideTag = false
            } else if !insideTag {
                text.append(character)
            }
        }
        return decodeEntities(text)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// `&amp;` and `&#39;` written back as the characters they name; one this
    /// does not know is left as it is written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].firstIndex(of: ";"),
                  text.distance(from: index, to: semicolon) <= 10
            else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index) ..< semicolon])
            if let decoded = entity(name) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    /// A character reference's text, or nil for one it does not know.
    static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "hellip": return "…"
        case "mdash": return "—"
        case "ndash": return "–"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "lsquo": return "‘"
        case "rsquo": return "’"
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                return UInt32(name.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map(text)
            }
            if name.hasPrefix("#") {
                return UInt32(name.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map(text)
            }
            return nil
        }
    }

    /// One scalar as the text it names.
    static func text(_ scalar: Unicode.Scalar) -> String {
        var view = String.UnicodeScalarView()
        view.append(scalar)
        return String(view)
    }

    /// Where a result's link really goes: DuckDuckGo wraps one in a redirect
    /// (`//duckduckgo.com/l/?uddg=…`), and anything that is not http or https
    /// is not a page to offer.
    static func destination(_ href: String) -> String {
        var link = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if link.hasPrefix("//") { link = "https:" + link }
        if let components = URLComponents(string: link),
           let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            link = target
        }
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return "" }
        return link
    }
}