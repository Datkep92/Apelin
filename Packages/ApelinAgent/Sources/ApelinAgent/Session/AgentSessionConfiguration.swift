import Foundation
import KWWKAgent
import KWWKAI

/// How a session is opened. The host fills it from the app's settings and
/// the project record; the agent cannot change any of it.
public struct AgentSessionConfiguration: Sendable {
    /// A UUID string; also the session folder's name.
    public var id: String
    public var project: ProjectIdentity
    public var temporaryID: String?
    public var provider: ProviderConfiguration
    public var approval: ApprovalPolicy
    public var dataRoot: ApelinDataRoot
    public var mcpServers: [MCPServerConfiguration]
    public var thinking: ThinkingLevel
    /// The processing tier its requests ask for; nil is the provider's default.
    public var serviceTier: ServiceTier?
    /// Hard cap on assistant turns per run; nil for none.
    public var maxTurns: Int?
    /// The install root the session host derived from its own path, which
    /// the system prompt names with the bootstrap; nil where there is none
    /// (the Mac tests).
    public var installRoot: String?

    public init(
        id: String = UUID().uuidString,
        project: ProjectIdentity,
        temporaryID: String? = nil,
        provider: ProviderConfiguration,
        approval: ApprovalPolicy,
        dataRoot: ApelinDataRoot = .current,
        mcpServers: [MCPServerConfiguration] = [],
        thinking: ThinkingLevel = .off,
        serviceTier: ServiceTier? = nil,
        maxTurns: Int? = nil,
        installRoot: String? = nil,
    ) {
        self.id = id
        self.project = project
        self.temporaryID = temporaryID
        self.provider = provider
        self.approval = approval
        self.dataRoot = dataRoot
        self.mcpServers = mcpServers
        self.thinking = thinking
        self.serviceTier = serviceTier
        self.maxTurns = maxTurns
        self.installRoot = installRoot
    }
}
