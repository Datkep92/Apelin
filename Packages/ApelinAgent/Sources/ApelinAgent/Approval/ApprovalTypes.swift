import Foundation

/// The two approval modes (§7).
public enum ApprovalMode: String, Sendable, Hashable, Codable {
    /// Everything runs.
    case relaxed
    /// Project edits run; preset reads and commands run; build and install
    /// run while their descriptions match the template or an approved
    /// digest; everything else asks, every time.
    case confirm
}

/// A request for the user's decision. The session is suspended on it until
/// `AgentSession.approve` answers or the run is aborted.
public struct ApprovalRequest: Sendable, Hashable, Codable {
    public var id: String
    public var toolCallID: String
    public var tool: String
    /// The arguments as canonical JSON text.
    public var arguments: String
    /// Relative to the project root.
    public var workingDirectory: String
    public var projectID: String
    /// Binds the decision to tool, arguments, working directory, project
    /// and (for build/install) the description digest. Changing any of them
    /// is a different request.
    public var fingerprint: String
    /// Why the gate asked, in a sentence.
    public var reason: String
    public var detail: ApprovalDetail
    /// Whether "for this session" may be offered. Never for package removal,
    /// a push, or a request bound to a description digest (the host's
    /// ledger keeps those).
    public var allowsSessionScope: Bool

    public init(
        id: String,
        toolCallID: String,
        tool: String,
        arguments: String,
        workingDirectory: String,
        projectID: String,
        fingerprint: String,
        reason: String,
        detail: ApprovalDetail,
        allowsSessionScope: Bool,
    ) {
        self.id = id
        self.toolCallID = toolCallID
        self.tool = tool
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.projectID = projectID
        self.fingerprint = fingerprint
        self.reason = reason
        self.detail = detail
        self.allowsSessionScope = allowsSessionScope
    }
}

/// What the approval card shows besides the tool and its arguments.
public enum ApprovalDetail: Sendable, Hashable, Codable {
    case none
    /// A build or packaging description that differs from its baseline: the
    /// digest the approval binds to, and the diff against the template or
    /// the last approved version.
    case descriptionChanged(kind: DescriptionKind, digest: String, diff: String)
    /// A command the presets did not cover, as classified.
    case command(RunCodeInvocation)
    /// A managed package removal.
    case packageRemoval(installationID: String)
    /// A push: the remote and the local branch it sends, resolved before
    /// asking (nil only when no branch is checked out).
    case gitPush(remote: String, branch: String?)
    /// A change to the device's git settings: the author, or the credential
    /// saved for a host (never its token).
    case gitSettings(summary: String)
}

public enum ApprovalDecision: Sendable, Hashable, Codable {
    public enum Scope: String, Sendable, Hashable, Codable {
        /// This call only.
        case once
        /// Identical calls (same fingerprint) for the rest of this session.
        case session
    }

    case approve(Scope)
    case deny(reason: String?)
}

// MARK: - Descriptions and their digests

public enum DescriptionKind: String, Sendable, Hashable, Codable {
    /// `apelin-project.json`'s build steps, compile/link flags and the
    /// build scripts the project carries.
    case build
    /// Control fields, maintainer scripts, install layout and dependencies.
    case packaging
}

/// The current state of a project's build or packaging description, as the
/// host computed it from the project and its registered template.
public struct DescriptionState: Sendable, Hashable, Codable {
    public enum Baseline: Sendable, Hashable, Codable {
        /// Byte-for-byte the template's (at the project's registered
        /// template version).
        case matchesTemplate
        /// Differs from the template, but this digest was approved before.
        case approved
        /// Differs and was never approved: the first run after the change
        /// asks. `diff` is against the template or the last approved
        /// version.
        case changed(diff: String)
    }

    /// SHA-256 of the description, hex.
    public var digest: String
    public var baseline: Baseline

    public init(digest: String, baseline: Baseline) {
        self.digest = digest
        self.baseline = baseline
    }
}

/// The host's record of description digests. Read-only from the agent's
/// side: there is no method that writes, and the ledger lives in the host's
/// private state, bound to the project id, where neither the agent nor a
/// project file can reach it. The host records an approval itself when it
/// relays the user's decision on a `.descriptionChanged` request.
public protocol ApprovalDigestStore: Sendable {
    func state(of kind: DescriptionKind, for project: ProjectIdentity) async throws -> DescriptionState
}
