import ApelinCore
import ApelinProtocol
import Foundation

/// The part of GitHub's REST API a package repository needs, called with the
/// github.com credential the user signed in with: the account, its own
/// repositories, making one, and GitHub Pages; the issue feedback files; and
/// the empty repository a project is pushed to (`gitRepositoryCreate`). The
/// token goes in the `Authorization` header to api.github.com and nowhere
/// else; no message quotes it.
struct GitHubAPI: Sendable {
    static let base = URL(string: "https://api.github.com")!
    typealias Exchange = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    let token: String
    let exchange: Exchange

    /// The API with the github.com sign-in, or the refusal that names it.
    static func signedIn(_ credentials: any GitCredentialStore, exchange: @escaping Exchange) throws -> GitHubAPI {
        guard let credential = try credentials.credential(forHost: GitHubHost.name), !credential.token.isEmpty else {
            throw ApelinError(.denied, "Sign in with GitHub in Settings ▸ Git first.", reason: .authenticationRequired)
        }
        return GitHubAPI(token: credential.token, exchange: exchange)
    }

    static let live: Exchange = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ApelinError(.unavailable, "GitHub's answer could not be read.")
        }
        return (data, response)
    }

    struct Owner: Decodable, Sendable {
        let login: String
    }

    struct Repository: Decodable, Sendable {
        let name: String
        let fullName: String
        let owner: Owner
        let isPrivate: Bool
        let description: String?
        let htmlURL: String
        let cloneURL: String
        let defaultBranch: String?
        let hasPages: Bool?
        let permissions: Permissions?

        struct Permissions: Decodable, Sendable {
            let push: Bool?
        }

        enum CodingKeys: String, CodingKey {
            case name, owner, description, permissions
            case fullName = "full_name"
            case isPrivate = "private"
            case htmlURL = "html_url"
            case cloneURL = "clone_url"
            case defaultBranch = "default_branch"
            case hasPages = "has_pages"
        }
    }

    struct Issue: Decodable, Sendable {
        let number: Int
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case number
            case htmlURL = "html_url"
        }
    }

    struct Pages: Decodable, Sendable {
        let htmlURL: String?
        let buildType: String?

        enum CodingKeys: String, CodingKey {
            case htmlURL = "html_url"
            case buildType = "build_type"
        }
    }

    /// The signed-in account's login.
    func login() async throws -> String {
        try await send("GET", "/user", as: Owner.self).login
    }

    /// The account's own repositories and its organizations', most recently
    /// updated first.
    func repositories() async throws -> [Repository] {
        try await send(
            "GET",
            "/user/repos?affiliation=owner,organization_member&sort=updated&per_page=100",
            as: [Repository].self,
        )
    }

    /// The organizations the account belongs to. With only the `repo` scope
    /// GitHub may leave out a membership the organization keeps private.
    func organizations() async throws -> [String] {
        try await send("GET", "/user/orgs?per_page=100", as: [Owner].self).map(\.login)
    }

    func repository(_ fullName: String) async throws -> Repository {
        try await send("GET", "/repos/\(fullName)", as: Repository.self)
    }

    /// A new repository on the account, or in `organization`, with nothing
    /// in it: no README, licence or `.gitignore`, so a first push lays down
    /// its history. `features` are GitHub's `has_*` switches; one not named
    /// keeps GitHub's default.
    func createRepository(
        name: String,
        description: String?,
        isPrivate: Bool,
        organization: String? = nil,
        features: [String: Bool] = [:],
    ) async throws -> Repository {
        var body: [String: Any] = ["name": name, "private": isPrivate, "auto_init": false]
        for (feature, isOn) in features {
            body[feature] = isOn
        }
        if let description {
            body["description"] = description
        }
        let path = organization.map { "/orgs/\($0)/repos" } ?? "/user/repos"
        return try await send("POST", path, body: body, as: Repository.self)
    }

    /// The repository's Pages site, nil when it has none.
    func pages(_ fullName: String) async throws -> Pages? {
        do {
            return try await send("GET", "/repos/\(fullName)/pages", as: Pages.self)
        } catch let error as ApelinError where error.code == .notFound {
            return nil
        }
    }

    /// Pages built by the repository's workflow (`build_type: workflow`):
    /// turned on, or switched from a branch source.
    func enableWorkflowPages(_ fullName: String) async throws -> Pages? {
        let body = ["build_type": "workflow"]
        switch try await pages(fullName) {
        case nil:
            _ = try await send("POST", "/repos/\(fullName)/pages", body: body, as: Pages.self)
        case let site? where site.buildType != "workflow":
            try await sendExpectingNothing("PUT", "/repos/\(fullName)/pages", body: body)
        default:
            break
        }
        return try await pages(fullName)
    }

    /// A new issue on `fullName`, opened by the signed-in account.
    func createIssue(_ fullName: String, title: String, body: String) async throws -> Issue {
        try await send("POST", "/repos/\(fullName)/issues", body: ["title": title, "body": body], as: Issue.self)
    }

    // MARK: Requests

    private func request(_ method: String, _ path: String, body: Any?) throws -> URLRequest {
        guard let url = URL(string: Self.base.absoluteString + path) else {
            throw ApelinError(.badRequest, "bad GitHub path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    private func send<T: Decodable>(_ method: String, _ path: String, body: Any? = nil, as _: T.Type) async throws -> T {
        let (data, response) = try await exchange(request(method, path, body: body))
        try Self.check(response, data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApelinError(.unavailable, "GitHub's answer to \(method) \(Self.route(path)) could not be read.")
        }
    }

    private func sendExpectingNothing(_ method: String, _ path: String, body: Any? = nil) async throws {
        let (data, response) = try await exchange(request(method, path, body: body))
        try Self.check(response, data)
    }

    /// The path without its query, for a message.
    private static func route(_ path: String) -> String {
        String(path.prefix { $0 != "?" })
    }

    /// GitHub's refusal in its own words, with the code Apelin gives it.
    static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200 ..< 300).contains(response.statusCode) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var message = object?["message"] as? String ?? "HTTP \(response.statusCode)"
        if let errors = object?["errors"] as? [[String: Any]] {
            let details = errors.compactMap { $0["message"] as? String }
            if !details.isEmpty {
                message += ": " + details.joined(separator: "; ")
            }
        }
        switch response.statusCode {
        case 401:
            throw ApelinError(
                .denied,
                "GitHub refused the saved sign-in. Sign in with GitHub again in Settings ▸ Git.",
                reason: .authenticationRequired,
            )
        case 403:
            throw ApelinError(.denied, "GitHub refused: \(message)")
        case 404:
            throw ApelinError(.notFound, "GitHub has no such repository, or the sign-in cannot see it.")
        case 409, 422:
            throw ApelinError(.conflict, "GitHub refused: \(message)")
        default:
            throw ApelinError(.unavailable, "GitHub answered \(response.statusCode): \(message)")
        }
    }
}
