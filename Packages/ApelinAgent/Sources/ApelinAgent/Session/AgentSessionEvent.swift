import ApelinProtocol
import Foundation

/// What a session tells the app. Each one is written to the session's event
/// log with a sequence number before it is delivered, so an app that was
/// killed, resprung or suspended reattaches with `afterSeq` and misses
/// nothing.
public enum AgentSessionEvent: Sendable, Hashable, Codable {
    /// A prompt entered the session (also queued follow-ups). `from`: the
    /// conversation of this project whose agent sent it, not the user.
    case promptSubmitted(text: String, from: String? = nil)
    /// `retryOf`: the message this one is sent again in place of, when a
    /// model failed to answer it and another candidate answers the same
    /// request (`ChatRuntime`), so the app keeps one row for both. nil for a
    /// message the user typed.
    case userMessage(id: UUID, text: String, attachments: [AgentAttachment], retryOf: UUID? = nil)
    /// A message sent while a run was going: queued for the run's next
    /// step, and a `userMessage` of the same id once the run takes it.
    case userMessageQueued(id: UUID, text: String, attachments: [AgentAttachment])
    /// Queued messages the run never took, because it was stopped first.
    case queuedMessagesDropped(ids: [UUID])
    case titleUpdated(String)
    case projectNameSuggested(String)
    /// A steering message was queued for the running turn.
    case steered(text: String)
    /// A model turn started streaming.
    case messageStarted
    /// The message streaming since the last `messageStarted` was given up
    /// and is asked for again: its text and thinking are not the reply.
    case messageDiscarded
    /// A model request failed and is being made again: kwwk's retry, or a
    /// wait for the network to come back (`NetworkRecovery`).
    case reconnecting
    /// Streamed assistant text.
    case textDelta(String)
    /// Streamed reasoning text.
    case thinkingDelta(String)
    /// The model began writing a tool call; the call itself follows once its
    /// arguments are whole, which for a long file can take a while.
    case toolCallPreparing
    /// The assistant message is complete; `text` is all of its text.
    case messageFinished(text: String)
    /// The output tokens the run has received so far (`OutputTally`):
    /// recorded a few times a second while a message streams, and when it
    /// ends, at the provider's count where it gave one.
    case received(tokens: Int)
    /// What the provider said the request that just finished cost it: the
    /// prompt it read (`input`), how much of that prompt its cache answered
    /// (`cacheRead`) and how much it wrote into that cache (`cacheWrite`),
    /// and what it wrote back (`output`). One per model message, so the app
    /// measures caching from the provider's own count instead of guessing;
    /// a route that reports nothing records no event.
    case usage(input: Int, output: Int, cacheRead: Int, cacheWrite: Int)
    case toolCallStarted(ToolCallRecord)
    case toolCallFinished(ToolResultRecord)
    /// The session is waiting: nothing runs until `approve` answers, and an
    /// app that is not connected leaves it waiting.
    case approvalRequested(ApprovalRequest)
    case approvalResolved(requestID: String, decision: ApprovalDecision)
    /// The agent asked Apelin to tell the user something while they are
    /// away (`apelin_notification_send`): plain text within `AgentNoticeRules`' lengths,
    /// which the session host posts as a banner by its own rules.
    case notice(title: String?, body: String)
    /// The assistant's plan, whole: the steps of the work the user asked
    /// for and where each one stands. Written every time the plan is
    /// written, so the app that reattaches, the bar and a conversation
    /// opened again all read the latest one — the plan lives in the log,
    /// not in a model's context, and outlives a compaction.
    case plan(AgentPlan)
    /// The plan was forgotten on the user's word: the bar goes, and no step
    /// stands any more.
    case planCleared
    case error(message: String)
    /// The model the run asked failed, in a way another configuration of the
    /// provider or another model may answer: an allowance that is spent, a
    /// key the provider refused, a route that is not there. `choice` is the
    /// choice the run was asking with, which the reader may have switched
    /// past while it ran, so the app knows which of its configurations
    /// failed. The `error` beside it is the row the reader sees.
    case modelFailed(message: String, choice: AgentRunChoice)
    /// A run ended.
    case finished(reason: FinishReason)
    /// The app asked to compact the conversation, between runs.
    case compactionStarted
    /// The compaction ended; a message sent meanwhile starts its run now.
    case compactionFinished(AgentCompactionResult)
}

/// The choice a run was asking with when it failed (`modelFailed`): the
/// provider, the saved configuration of it (`AgentProfileID`) and the model
/// name the prompt asked for. The app compares it with the configurations it
/// knows, and with the one that failed last, to decide which key to leave
/// alone and which to try next.
public struct AgentRunChoice: Sendable, Hashable, Codable {
    public var provider: AgentProvider
    /// The saved configuration of `provider`; nil is the provider's own,
    /// first one.
    public var configuration: String?
    /// The model the prompt named; nil when it named none.
    public var model: String?

    public init(provider: AgentProvider, configuration: String? = nil, model: String? = nil) {
        self.provider = provider
        self.configuration = configuration
        self.model = model
    }
}

public enum FinishReason: String, Sendable, Hashable, Codable {
    case completed
    case aborted
    case failed
}

public struct ToolCallRecord: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The arguments as JSON text.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResultRecord: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The text the model saw, bounded. Images are recorded as attachment
    /// ids, never inline.
    public var output: String
    public var isError: Bool
    public var attachments: [AgentAttachment]?

    public init(id: String, name: String, output: String, isError: Bool, attachments: [AgentAttachment]? = nil) {
        self.id = id
        self.name = name
        self.output = output
        self.isError = isError
        self.attachments = attachments
    }
}

/// One line of `events.jsonl`.
public struct SessionEventRecord: Sendable, Hashable, Codable {
    public var seq: UInt64
    public var date: Date
    public var event: AgentSessionEvent

    public init(seq: UInt64, date: Date, event: AgentSessionEvent) {
        self.seq = seq
        self.date = date
        self.event = event
    }
}
