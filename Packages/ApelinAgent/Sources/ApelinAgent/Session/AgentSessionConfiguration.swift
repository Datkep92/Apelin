import Foundation
import KWWKAgent

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
    /// Hard cap on assistant turns per run; nil for none.
    public var maxTurns: Int?

    public init(
        id: String = UUID().uuidString,
        project: ProjectIdentity,
        temporaryID: String? = nil,
        provider: ProviderConfiguration,
        approval: ApprovalPolicy,
        dataRoot: ApelinDataRoot = .current,
        mcpServers: [MCPServerConfiguration] = [],
        thinking: ThinkingLevel = .off,
        maxTurns: Int? = nil,
    ) {
        self.id = id
        self.project = project
        self.temporaryID = temporaryID
        self.provider = provider
        self.approval = approval
        self.dataRoot = dataRoot
        self.mcpServers = mcpServers
        self.thinking = thinking
        self.maxTurns = maxTurns
    }
}
