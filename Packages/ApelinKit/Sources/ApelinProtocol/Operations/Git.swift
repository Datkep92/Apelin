// The git service on a project: clone, status, diff, stage, unstage, local
// commit, fetch, a fast-forward pull and push, and the settings behind
// them — the commit author and one HTTPS credential per host.
// Served by apelin-environment (Workers/Environment; ApelinGit, libgit2).
//
// `projectID` is the `projectID` in a project's apelin-project.json, or, for
// a folder that has none yet (a fresh clone), the project's folder name.
// The worker resolves it to `~/Documents/wiki.qaq.apelin/Projects/<name>/`
// with realpath and a component compare, and every path is relative to it.
// A commit's author is the request's, else Settings/git.json in the data
// folder ({"authorName", "authorEmail"}), else the repository's own config.

public struct GitStatusEntry: Codable, Sendable, Equatable {
    public var path: String
    /// One-letter states as `git status --porcelain` spells them.
    public var index: String
    public var worktree: String

    public init(path: String, index: String, worktree: String) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
}

public struct GitStatusRequest: OperationRequest {
    public typealias Response = GitStatusResponse
    public static let operation = AppOperation.gitStatus
    public var projectID: String
    public init(projectID: String) {
        self.projectID = projectID
    }
}

public struct GitStatusResponse: Codable, Sendable, Equatable {
    public var branch: String?
    public var head: String?
    public var entries: [GitStatusEntry]

    public init(branch: String? = nil, head: String? = nil, entries: [GitStatusEntry] = []) {
        self.branch = branch
        self.head = head
        self.entries = entries
    }
}

public struct GitDiffRequest: OperationRequest {
    public typealias Response = GitDiffResponse
    public static let operation = AppOperation.gitDiff
    public var projectID: String
    /// Project-relative; nil diffs everything.
    public var path: String?
    /// The index against HEAD rather than the worktree against the index.
    public var staged: Bool

    public init(projectID: String, path: String? = nil, staged: Bool = false) {
        self.projectID = projectID
        self.path = path
        self.staged = staged
    }

    /// `staged` may be left out, and is then false.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(String.self, forKey: .projectID)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
    }
}

public struct GitDiffResponse: Codable, Sendable, Equatable {
    /// A unified diff.
    public var diff: String
    public init(diff: String) {
        self.diff = diff
    }
}

public struct GitStageRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitStage
    public var projectID: String
    public var paths: [String]

    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public struct GitUnstageRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitUnstage
    public var projectID: String
    public var paths: [String]

    public init(projectID: String, paths: [String]) {
        self.projectID = projectID
        self.paths = paths
    }
}

public struct GitCommitRequest: OperationRequest {
    public typealias Response = GitCommitResponse
    public static let operation = AppOperation.gitCommit
    public var projectID: String
    public var message: String
    public var authorName: String?
    public var authorEmail: String?

    public init(projectID: String, message: String, authorName: String? = nil, authorEmail: String? = nil) {
        self.projectID = projectID
        self.message = message
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

public struct GitCommitResponse: Codable, Sendable, Equatable {
    public var commitID: String
    public init(commitID: String) {
        self.commitID = commitID
    }
}

/// Starts a project from a repository: a shallow clone (depth 1, no tags)
/// of one branch over HTTPS into `Projects/<projectName>/`, which must not
/// exist yet. A task of kind `environment`; its events are `progress`
/// {stage: "fetching", completed, total, detail} and, before the final
/// `state`, `result` {projectName, branch, commit}.
public struct GitCloneRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitClone
    public var url: String
    public var branch: String
    public var projectName: String

    public init(url: String, branch: String, projectName: String) {
        self.url = url
        self.branch = branch
        self.projectName = projectName
    }
}

/// Imports a repository into a project that already exists — an empty
/// workspace — rather than making a new folder: the repository is
/// initialised in the project folder, `origin` set to `url`, fetched in
/// full, and `branch` (nil: the remote's default) checked out over it
/// without overwriting anything already there, so a repository that has a
/// file of the same name as one in the folder fails and leaves the folder
/// as it was. `apelin-project.json` is kept out of the repository through
/// `.git/info/exclude`. HTTPS only; a credential saved for the URL's host
/// is used. A task of kind `environment`; events `progress` {stage:
/// "fetching", …}, then `result` {branch, commit} before the final `state`.
public struct GitCloneIntoRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitCloneInto
    public var projectID: String
    public var url: String
    public var branch: String?

    public init(projectID: String, url: String, branch: String? = nil) {
        self.projectID = projectID
        self.url = url
        self.branch = branch
    }
}

/// Fetches a remote's branches (nil: `origin`) into its remote-tracking
/// refs; the worktree and the branches are left alone. A task of kind
/// `environment`; `progress` {stage: "fetching", …}, then `result` {remote,
/// updated: [{ref, from?, to}]}.
public struct GitFetchRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitFetch
    public var projectID: String
    public var remote: String?

    public init(projectID: String, remote: String? = nil) {
        self.projectID = projectID
        self.remote = remote
    }
}

/// Fetches, then fast-forwards the checked-out branch to its upstream
/// (`branch.<name>.remote`/`merge`, else `<remote>/<name>`). Never merges
/// or rebases: a branch that has diverged, or a worktree change the
/// fast-forward would overwrite, fails with `conflict` and changes nothing.
/// A task of kind `environment`; `result` {branch, from, to, upToDate}.
public struct GitPullRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitPull
    public var projectID: String
    public var remote: String?

    public init(projectID: String, remote: String? = nil) {
        self.projectID = projectID
        self.remote = remote
    }
}

/// Pushes a local branch (nil: the checked-out one) to the branch of the
/// same name on a remote (nil: `origin`), and records it as the branch's
/// upstream. Never forced: a rejected update fails with `conflict`. HTTPS
/// only, with the credential saved for the remote's host. A task of kind
/// `environment`; `progress` {stage: "pushing", …}, then `result` {remote,
/// branch, commit}.
public struct GitPushRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.gitPush
    public var projectID: String
    public var remote: String?
    public var branch: String?

    public init(projectID: String, remote: String? = nil, branch: String? = nil) {
        self.projectID = projectID
        self.remote = remote
        self.branch = branch
    }
}

// MARK: Settings and credentials (the app's only)

/// A saved HTTPS credential as the settings list shows it; the token never
/// leaves apelin-environment's keychain item.
public struct GitCredentialSummary: Codable, Sendable, Equatable, Hashable {
    /// Lowercased, with `:port` when the URL names one: what a remote's
    /// host must equal for the credential to be offered to it.
    public var host: String
    public var username: String

    public init(host: String, username: String) {
        self.host = host
        self.username = username
    }
}

/// The commit author and the saved credentials.
public struct GitSettingsRequest: OperationRequest {
    public typealias Response = GitSettingsResponse
    public static let operation = AppOperation.gitSettings
    public init() {}
}

public struct GitSettingsResponse: Codable, Sendable, Equatable {
    public var authorName: String?
    public var authorEmail: String?
    /// Sorted by host.
    public var credentials: [GitCredentialSummary]

    public init(authorName: String? = nil, authorEmail: String? = nil, credentials: [GitCredentialSummary] = []) {
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.credentials = credentials
    }
}

/// Writes `Settings/git.json`; a nil or empty field is removed.
public struct GitAuthorSetRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitAuthorSet
    public var authorName: String?
    public var authorEmail: String?

    public init(authorName: String?, authorEmail: String?) {
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

/// Saves, or replaces, the credential for one host: a username and a token
/// (a personal access token, used as the HTTPS password). Kept in
/// apelin-environment's keychain group, this device only, never
/// synchronised; no reply, event or log carries the token, and the console
/// refuses this operation before sending it.
public struct GitCredentialSetRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitCredentialSet
    /// A host name, optionally `:port`; no scheme, path or user. Compared
    /// lowercased.
    public var host: String
    public var username: String
    public var token: String

    public init(host: String, username: String, token: String) {
        self.host = host
        self.username = username
        self.token = token
    }
}

public struct GitCredentialRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gitCredentialRemove
    public var host: String

    public init(host: String) {
        self.host = host
    }
}

public extension ApelinService {
    func gitStatus(projectID: String) async throws -> GitStatusResponse {
        try await send(GitStatusRequest(projectID: projectID))
    }

    func gitDiff(projectID: String, path: String? = nil, staged: Bool = false) async throws -> GitDiffResponse {
        try await send(GitDiffRequest(projectID: projectID, path: path, staged: staged))
    }

    func gitStage(projectID: String, paths: [String]) async throws {
        _ = try await send(GitStageRequest(projectID: projectID, paths: paths))
    }

    func gitUnstage(projectID: String, paths: [String]) async throws {
        _ = try await send(GitUnstageRequest(projectID: projectID, paths: paths))
    }

    func gitCommit(_ request: GitCommitRequest) async throws -> GitCommitResponse {
        try await send(request)
    }

    /// Starts a clone; follow it with `events(of:)`.
    func gitClone(url: String, branch: String, projectName: String) async throws -> TaskHandle {
        try await send(GitCloneRequest(url: url, branch: branch, projectName: projectName))
    }

    /// Starts an import into an existing project; follow it with `events(of:)`.
    func gitCloneInto(_ request: GitCloneIntoRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func gitFetch(projectID: String, remote: String? = nil) async throws -> TaskHandle {
        try await send(GitFetchRequest(projectID: projectID, remote: remote))
    }

    func gitPull(projectID: String, remote: String? = nil) async throws -> TaskHandle {
        try await send(GitPullRequest(projectID: projectID, remote: remote))
    }

    func gitPush(_ request: GitPushRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func gitSettings() async throws -> GitSettingsResponse {
        try await send(GitSettingsRequest())
    }

    func gitAuthorSet(name: String?, email: String?) async throws {
        _ = try await send(GitAuthorSetRequest(authorName: name, authorEmail: email))
    }

    func gitCredentialSet(_ request: GitCredentialSetRequest) async throws {
        _ = try await send(request)
    }

    func gitCredentialRemove(host: String) async throws {
        _ = try await send(GitCredentialRemoveRequest(host: host))
    }
}
