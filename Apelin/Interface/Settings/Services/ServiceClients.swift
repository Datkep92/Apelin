import Foundation

/// Firebase Management API client. Uses a Google OAuth access token to list
/// and select Firebase projects, mapping each to an Apelin project.
struct FirebaseServiceClient: Sendable {
    let accessToken: String

    private let baseURL = URL(string: "https://firebase.googleapis.com/v1beta1")!

    /// List Firebase projects the authenticated user can access.
    func listProjects() async throws -> [FirebaseProject] {
        let url = baseURL.appendingPathComponent("projects")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let projects = json["results"] as? [[String: Any]] ?? json["projects"] as? [[String: Any]] ?? []
        return projects.compactMap { dict in
            guard let name = dict["projectId"] as? String ?? dict["name"] as? String else { return nil }
            let displayName = dict["displayName"] as? String
            return FirebaseProject(id: name, displayName: displayName)
        }
    }

    /// Get project details including apps.
    func getProject(projectID: String) async throws -> FirebaseProject {
        let url = baseURL.appendingPathComponent("projects/\(projectID)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let id = json["projectId"] as? String ?? projectID
        let displayName = json["displayName"] as? String
        return FirebaseProject(id: id, displayName: displayName)
    }
}

struct FirebaseProject: Equatable, Sendable, Identifiable {
    let id: String
    let displayName: String?
}

/// Cloudflare API client. Uses an API token to list accounts, zones, workers,
/// and Pages projects.
struct CloudflareServiceClient: Sendable {
    let apiToken: String

    private let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    /// Validate the API token and return the user's email.
    func validateToken() async throws -> String {
        let url = baseURL.appendingPathComponent("user/tokens/verify")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let result = json["result"] as? [String: Any] ?? [:]
        return result["id"] as? String ?? "valid"
    }

    /// List accounts the token can access.
    func listAccounts() async throws -> [CloudflareAccount] {
        let url = baseURL.appendingPathComponent("accounts")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let results = json["result"] as? [[String: Any]] ?? []
        return results.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let name = dict["name"] as? String
            return CloudflareAccount(id: id, name: name)
        }
    }

    /// List zones for an account.
    func listZones(accountID: String) async throws -> [CloudflareZone] {
        var components = URLComponents(url: baseURL.appendingPathComponent("zones"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "account.id", value: accountID)]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let results = json["result"] as? [[String: Any]] ?? []
        return results.compactMap { dict in
            guard let id = dict["id"] as? String else { return nil }
            let name = dict["name"] as? String
            return CloudflareZone(id: id, name: name)
        }
    }

    /// List Workers for an account.
    func listWorkers(accountID: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent("accounts/\(accountID)/workers/scripts")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let results = json["result"] as? [[String: Any]] ?? []
        return results.compactMap { $0["id"] as? String ?? $0["name"] as? String }
    }

    /// List Pages projects for an account.
    func listPagesProjects(accountID: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent("accounts/\(accountID)/pages/projects")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let results = json["result"] as? [[String: Any]] ?? []
        return results.compactMap { $0["name"] as? String }
    }
}

struct CloudflareAccount: Equatable, Sendable, Identifiable {
    let id: String
    let name: String?
}

struct CloudflareZone: Equatable, Sendable, Identifiable {
    let id: String
    let name: String?
}

/// Google Apps Script API client. Uses a Google OAuth access token to list
/// and select script projects.
struct GoogleScriptServiceClient: Sendable {
    let accessToken: String

    private let baseURL = URL(string: "https://script.googleapis.com/v1")!

    /// List script projects the user can access.
    func listProjects() async throws -> [GoogleScriptProject] {
        let url = baseURL.appendingPathComponent("projects")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "50")]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let projects = json["projects"] as? [[String: Any]] ?? []
        return projects.compactMap { dict in
            guard let id = dict["scriptId"] as? String else { return nil }
            let title = dict["title"] as? String
            return GoogleScriptProject(id: id, title: title)
        }
    }

    /// Get a specific project's details.
    func getProject(scriptID: String) async throws -> GoogleScriptProject {
        let url = baseURL.appendingPathComponent("projects/\(scriptID)")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let id = json["scriptId"] as? String ?? scriptID
        let title = json["title"] as? String
        return GoogleScriptProject(id: id, title: title)
    }
}

struct GoogleScriptProject: Equatable, Sendable, Identifiable {
    let id: String
    let title: String?
}

/// Telegram Bot API client. Uses a bot token to validate and send messages.
struct TelegramServiceClient: Sendable {
    let botToken: String

    private var baseURL: URL {
        URL(string: "https://api.telegram.org/bot\(botToken)")!
    }

    /// Validate the bot token and return the bot's info.
    func getMe() async throws -> TelegramBotInfo {
        let url = baseURL.appendingPathComponent("getMe")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["ok"] as? Bool == true else {
            let desc = json["description"] as? String ?? "Unknown error"
            throw ServiceError.refused(desc)
        }
        let result = json["result"] as? [String: Any] ?? [:]
        let id = result["id"] as? Int ?? 0
        let firstName = result["first_name"] as? String
        let username = result["username"] as? String
        return TelegramBotInfo(id: id, firstName: firstName, username: username)
    }

    /// Send a message to a chat.
    func sendMessage(chatID: String, text: String) async throws {
        let url = baseURL.appendingPathComponent("sendMessage")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatID, "text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["ok"] as? Bool == true else {
            let desc = json["description"] as? String ?? "Unknown error"
            throw ServiceError.refused(desc)
        }
    }

    /// Get chat info.
    func getChat(chatID: String) async throws -> TelegramChatInfo {
        var components = URLComponents(url: baseURL.appendingPathComponent("getChat"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "chat_id", value: chatID)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard json["ok"] as? Bool == true else {
            let desc = json["description"] as? String ?? "Unknown error"
            throw ServiceError.refused(desc)
        }
        let result = json["result"] as? [String: Any] ?? [:]
        let id = result["id"] as? Int ?? 0
        let title = result["title"] as? String ?? result["first_name"] as? String
        let type = result["type"] as? String
        return TelegramChatInfo(id: id, title: title, type: type)
    }
}

struct TelegramBotInfo: Equatable, Sendable {
    let id: Int
    let firstName: String?
    let username: String?
}

struct TelegramChatInfo: Equatable, Sendable {
    let id: Int
    let title: String?
    let type: String?
}

/// Common service errors.
enum ServiceError: Error, LocalizedError {
    case httpError(Int)
    case refused(String)
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP error \(code)"
        case .refused(let reason): return reason
        case .invalidCredentials: return "Invalid credentials"
        }
    }
}
