import Foundation

/// Per-project configuration for external services (GitHub, Firebase,
/// Cloudflare, Google Script, Telegram). Each project stores its own
/// configuration so that multiple projects do not share one account or
/// repository.
struct ProjectServiceConfig: Codable, Equatable, Sendable {
    /// One Google OAuth client ID shared by Firebase, Google Script and Sheet.
    /// Optional so older per-project files keep decoding.
    var googleClientID: String?
    /// GitHub repository linked to this project.
    var github: GitHubServiceConfig?
    /// Firebase project linked to this project.
    var firebase: FirebaseServiceConfig?
    /// Cloudflare resources linked to this project.
    var cloudflare: CloudflareServiceConfig?
    /// Google Apps Script project linked to this project.
    var googleScript: GoogleScriptServiceConfig?
    /// Google Sheet linked to this project, by Google sign-in or a deployment link.
    var googleSheet: GoogleSheetServiceConfig?
    /// Telegram bot/channel linked to this project.
    var telegram: TelegramServiceConfig?

    static let empty = ProjectServiceConfig()
}

struct GitHubServiceConfig: Codable, Equatable, Sendable {
    var repositoryFullName: String?
    var repositoryURL: String?
    var defaultBranch: String?
}

struct FirebaseServiceConfig: Codable, Equatable, Sendable {
    var projectID: String?
    var appID: String?
    var apiKey: String?
    var storageBucket: String?
    var accessToken: String?
    var googleClientID: String?
}

struct CloudflareServiceConfig: Codable, Equatable, Sendable {
    var accountID: String?
    var zoneID: String?
    var workerName: String?
    var pagesProject: String?
    var apiToken: String?
}

struct GoogleScriptServiceConfig: Codable, Equatable, Sendable {
    var scriptID: String?
    var deploymentID: String?
    var webAppURL: String?
    var accessToken: String?
    var googleClientID: String?
}

/// A Google Sheet reached either with a Google access token (Sheets API) or
/// through an Apps Script deployment link. Both fields are optional so a
/// configuration can use either path without creating the other.
struct GoogleSheetServiceConfig: Codable, Equatable, Sendable {
    var spreadsheetID: String?
    var webAppURL: String?
    var accessToken: String?
    var googleClientID: String?
}

struct TelegramServiceConfig: Codable, Equatable, Sendable {
    var botToken: String?
    var chatID: String?
    var channelName: String?
    var botUsername: String?
}
