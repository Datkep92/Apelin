import Foundation
import KWWKAI

/// apelin_web_search: a broad search over the public internet without an API
/// key. Phase 1 gathers results from GitHub, Hacker News and Reddit.
struct WebSearch: Sendable {
    static let shared = WebSearch()
    static let perSourceLimit = 5
    static let timeoutSeconds = 30

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Self.timeoutSeconds)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Apelin",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }

    func search(_ arguments: JSONValue) async throws -> String {
        let query = arguments.requireString("query")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw ToolArgumentError("query is empty: say what should be searched for")
        }
        let limit = max(1, min(Self.perSourceLimit, arguments.argInt("limit") ?? Self.perSourceLimit))

        async let github = githubResults(query: query, limit: limit)
        async let hackerNews = hackerNewsResults(query: query, limit: limit)
        async let reddit = redditResults(query: query, limit: limit)

        var parts: [String] = []
        parts.append("Search results for \"\(query)\"")
        for (heading, result) in [
            ("GitHub repositories and issues", await github),
            ("Hacker News stories and comments", await hackerNews),
            ("Reddit posts and comments", await reddit),
        ] {
            parts.append("")
            parts.append("## \(heading)")
            if let text = result, !text.isEmpty {
                parts.append(text)
            } else {
                parts.append("(no results)")
            }
        }
        parts.append("")
        parts.append("Use apelin_web_fetch on a result URL to read the page.")
        return parts.joined(separator: "\n")
    }

    private func githubResults(query: String, limit: Int) async -> String? {
        guard var components = URLComponents(string: "https://api.github.com/search/repositories") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
        ]
        guard let url = components.url else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]]
            else { return nil }
            if items.isEmpty { return nil }
            return items.prefix(limit).map { item in
                let title = item["full_name"] as? String ?? item["name"] as? String ?? "result"
                let url = item["html_url"] as? String ?? ""
                let description = (item["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let stars = item["stargazers_count"] as? Int
                let starText = stars.map { " (\($0) stars)" } ?? ""
                return description.isEmpty
                    ? "- [\(title)](\(url))\(starText)"
                    : "- [\(title)](\(url))\(starText): \(description)"
            }.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func hackerNewsResults(query: String, limit: Int) async -> String? {
        guard var components = URLComponents(string: "https://hn.algolia.com/api/v1/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "hitsPerPage", value: String(limit)),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hits = json["hits"] as? [[String: Any]]
            else { return nil }
            if hits.isEmpty { return nil }
            return hits.prefix(limit).map { hit in
                let title = hit["title"] as? String ?? hit["story_title"] as? String ?? "result"
                let url = hit["url"] as? String ?? "https://news.ycombinator.com/item?id=\(hit["objectID"] as? String ?? "")"
                let points = hit["points"] as? Int ?? 0
                return "- [\(title)](\(url)) (\(points) points)"
            }.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func redditResults(query: String, limit: Int) async -> String? {
        guard var components = URLComponents(string: "https://www.reddit.com/search.json") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "relevance"),
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataNode = json["data"] as? [String: Any],
                  let children = dataNode["children"] as? [[String: Any]]
            else { return nil }
            let posts = children.compactMap { child -> String? in
                guard let post = child["data"] as? [String: Any] else { return nil }
                let title = post["title"] as? String ?? "result"
                let permalink = post["permalink"] as? String ?? ""
                let url = permalink.hasPrefix("http") ? permalink : "https://www.reddit.com\(permalink)"
                let score = post["score"] as? Int ?? 0
                return "- [\(title)](\(url)) (\(score) points)"
            }
            if posts.isEmpty { return nil }
            return posts.prefix(limit).joined(separator: "\n")
        } catch {
            return nil
        }
    }
}
