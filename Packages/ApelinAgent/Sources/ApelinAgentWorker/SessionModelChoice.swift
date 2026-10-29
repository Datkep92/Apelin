import ApelinProtocol

/// The provider, model, effort and tier a session runs with now: what its
/// open request named, then what each of the app's prompts named. A
/// conversation the session opens starts with the same.
public actor SessionModelChoice {
    public struct Choice: Sendable, Equatable {
        public var provider: AgentProvider?
        public var model: String?
        public var reasoningEffort: AgentReasoningEffort?
        public var serviceTier: AgentServiceTier?
        /// The configuration of `provider` the app picked (`AgentProfileID`);
        /// nil is the provider's own, first one.
        public var profileID: String?
    }

    public private(set) var current = Choice()

    public init(
        provider: AgentProvider? = nil,
        model: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier? = nil,
        profileID: String? = nil,
    ) {
        current = Choice(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            profileID: profileID,
        )
    }

    public func set(
        provider: AgentProvider?,
        model: String?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        profileID: String? = nil,
    ) {
        current = Choice(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            profileID: profileID,
        )
    }
}
