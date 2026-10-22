import ApelinProtocol

/// The provider, model and effort a session runs with now: what its open
/// request named, then what each of the app's prompts named. A
/// conversation the session opens starts with the same.
public actor SessionModelChoice {
    public struct Choice: Sendable, Equatable {
        public var provider: AgentProvider?
        public var model: String?
        public var reasoningEffort: AgentReasoningEffort?
    }

    public private(set) var current = Choice()

    public init(provider: AgentProvider? = nil, model: String? = nil, reasoningEffort: AgentReasoningEffort? = nil) {
        current = Choice(provider: provider, model: model, reasoningEffort: reasoningEffort)
    }

    public func set(provider: AgentProvider?, model: String?, reasoningEffort: AgentReasoningEffort?) {
        current = Choice(provider: provider, model: model, reasoningEffort: reasoningEffort)
    }
}
