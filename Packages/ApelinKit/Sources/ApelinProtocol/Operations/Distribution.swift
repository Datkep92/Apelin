// The package repository a user publishes to: an APT source in a GitHub
// repository of theirs, served by GitHub Pages and indexed there by the
// workflow Apelin's template brings (after owngoal-dev/owngoal-packages).
// Served by apelin-environment, which holds the github.com credential the
// user signed in with and calls GitHub's API with it; the app's alone.
//
// The repository's clone is a workspace project like any other, so its
// conversation maintains it with the file and git tools; the link is
// `Settings/distribution.json` in the data folder, naming the repository
// and that project.

/// The linked package repository.
public struct DistributionRepository: Codable, Sendable, Equatable, Hashable {
    /// `owner/name`.
    public var fullName: String
    /// Its page on GitHub, `https://github.com/owner/name`.
    public var url: String
    /// The address a package manager adds: the GitHub Pages site.
    public var sourceURL: String
    /// The workspace project holding its clone.
    public var projectID: String
    public var projectName: String

    public init(fullName: String, url: String, sourceURL: String, projectID: String, projectName: String) {
        self.fullName = fullName
        self.url = url
        self.sourceURL = sourceURL
        self.projectID = projectID
        self.projectName = projectName
    }
}

/// One of the signed-in account's own repositories, offered to link.
public struct DistributionRepositoryCandidate: Codable, Sendable, Equatable, Hashable {
    public var fullName: String
    public var isPrivate: Bool
    public var description: String?
    /// Whether it has a GitHub Pages site already.
    public var hasPages: Bool

    public init(fullName: String, isPrivate: Bool, description: String? = nil, hasPages: Bool = false) {
        self.fullName = fullName
        self.isPrivate = isPrivate
        self.description = description
        self.hasPages = hasPages
    }
}

/// The link, and with `repositories` the account's own repositories, which
/// asks GitHub. Without a github.com credential `account` is nil and the
/// list empty.
public struct DistributionRepositoryListRequest: OperationRequest {
    public typealias Response = DistributionRepositoryListResponse
    public static let operation = AppOperation.distributionRepositoryList
    public var repositories: Bool

    public init(repositories: Bool = true) {
        self.repositories = repositories
    }
}

public struct DistributionRepositoryListResponse: Codable, Sendable, Equatable {
    /// The login of the github.com credential, as saved.
    public var account: String?
    public var linked: DistributionRepository?
    /// The account's own and its organizations', each one it can push to,
    /// most recently updated first.
    public var repositories: [DistributionRepositoryCandidate]
    /// With `repositories`, the organizations a repository can be created
    /// in: those GitHub lists for the account and the owners of the
    /// organization repositories it listed, by name.
    public var organizations: [String]

    public init(
        account: String? = nil,
        linked: DistributionRepository? = nil,
        repositories: [DistributionRepositoryCandidate] = [],
        organizations: [String] = [],
    ) {
        self.account = account
        self.linked = linked
        self.repositories = repositories
        self.organizations = organizations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        linked = try container.decodeIfPresent(DistributionRepository.self, forKey: .linked)
        repositories = try container.decode([DistributionRepositoryCandidate].self, forKey: .repositories)
        organizations = try container.decodeIfPresent([String].self, forKey: .organizations) ?? []
    }
}

/// A task: makes `name` on the signed-in account, or in the organization
/// `owner` names, public, from Apelin's template, as a new workspace project; commits and pushes it, turns on
/// GitHub Pages with the workflow as its source and links it. Stages
/// `creating`, `preparing`, `pushing`, `publishing`; the final `state`
/// carries `result` {repository: DistributionRepository, warnings}.
public struct DistributionRepositoryCreateRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionRepositoryCreate
    public var name: String
    public var description: String?
    /// An organization's login; nil, or the account's own, for the account.
    public var owner: String?

    public init(name: String, description: String? = nil, owner: String? = nil) {
        self.name = name
        self.description = description
        self.owner = owner
    }
}

/// A task: clones one of the account's repositories as a new workspace
/// project (or takes the project already holding it), adds the template's
/// files it lacks without overwriting one, commits and pushes them when it
/// added any, turns on GitHub Pages with the workflow as its source and
/// links it. Stages `fetching`, `preparing`, `pushing`, `publishing`.
public struct DistributionRepositoryLinkRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionRepositoryLink
    /// `owner/name`.
    public var fullName: String

    public init(fullName: String) {
        self.fullName = fullName
    }
}

/// Forgets the link; the repository and its project stay.
public struct DistributionRepositoryUnlinkRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.distributionRepositoryUnlink

    public init() {}
}

/// A task: brings the linked repository up to date (fast-forward only),
/// copies each package into its `debs/` as
/// `<Package>_<Version>_<Architecture>.deb` — the same bytes already there
/// are skipped, other bytes under that name are `conflict` —, commits
/// "Publish …" and pushes. `files` are `.deb` files under the data folder's
/// `Builds/`. Stages `fetching`, `preparing`, `pushing`; the final `state`
/// carries `result` {published: [file names], skipped: [file names], commit?}.
public struct DistributionPublishRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.distributionPublish
    public var files: [String]

    public init(files: [String]) {
        self.files = files
    }
}

public extension ApelinService {
    func distributionRepositoryList(repositories: Bool = true) async throws -> DistributionRepositoryListResponse {
        try await send(DistributionRepositoryListRequest(repositories: repositories))
    }

    /// Starts the creation; follow it with `events(of:)`.
    func distributionRepositoryCreate(name: String, description: String? = nil, owner: String? = nil) async throws -> TaskHandle {
        try await send(DistributionRepositoryCreateRequest(name: name, description: description, owner: owner))
    }

    /// Starts the link; follow it with `events(of:)`.
    func distributionRepositoryLink(fullName: String) async throws -> TaskHandle {
        try await send(DistributionRepositoryLinkRequest(fullName: fullName))
    }

    func distributionRepositoryUnlink() async throws {
        _ = try await send(DistributionRepositoryUnlinkRequest())
    }

    /// Starts publishing; follow it with `events(of:)`.
    func distributionPublish(files: [String]) async throws -> TaskHandle {
        try await send(DistributionPublishRequest(files: files))
    }
}
