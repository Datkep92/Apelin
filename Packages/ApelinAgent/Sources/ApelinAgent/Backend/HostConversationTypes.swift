import Foundation

// MARK: - conversations

/// Every conversation call names the session's own project only through the
/// host: it opens, lists and reads the caller's project's conversations and
/// stops the ones the caller opened, whatever a request says.
public struct ConversationCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// The first message, read by the other agent as the user's.
    public var prompt: String
    public var title: String?
    public init(context: HostCallContext, prompt: String, title: String? = nil) {
        self.context = context
        self.prompt = prompt
        self.title = title
    }
}

public struct ConversationCreateToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    public var taskID: String
    public init(sessionID: String, taskID: String) {
        self.sessionID = sessionID
        self.taskID = taskID
    }
}

public struct ConversationSendToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var sessionID: String
    public var text: String
    public init(context: HostCallContext, sessionID: String, text: String) {
        self.context = context
        self.sessionID = sessionID
        self.text = text
    }
}

public struct ConversationStopToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var sessionID: String
    /// Also end the conversation, not only its turn.
    public var close: Bool
    public init(context: HostCallContext, sessionID: String, close: Bool = false) {
        self.context = context
        self.sessionID = sessionID
        self.close = close
    }
}

/// What a send or a stop did.
public struct ConversationActionToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    /// `sent`, `stopped` or `closed`.
    public var done: String
    public init(sessionID: String, done: String) {
        self.sessionID = sessionID
        self.done = done
    }
}

public struct ConversationSummary: Sendable, Hashable, Codable {
    public var sessionID: String
    public var title: String?
    /// `open` (running a turn or idle), `waitingForApproval` or `ended`.
    public var state: String
    /// The conversation whose agent opened it; nil for the user's.
    public var openedBy: String?
    public var updatedAt: Date
    public var isThisConversation: Bool
    public init(
        sessionID: String,
        title: String? = nil,
        state: String,
        openedBy: String? = nil,
        updatedAt: Date,
        isThisConversation: Bool = false,
    ) {
        self.sessionID = sessionID
        self.title = title
        self.state = state
        self.openedBy = openedBy
        self.updatedAt = updatedAt
        self.isThisConversation = isThisConversation
    }
}

public struct ConversationListToolResponse: Sendable, Hashable, Codable {
    public var conversations: [ConversationSummary]
    public init(conversations: [ConversationSummary]) {
        self.conversations = conversations
    }
}

public struct ConversationReadToolRequest: Sendable, Hashable, Codable {
    /// conversation_read waits at most ten minutes.
    public static let maximumWaitSeconds = 600

    public var context: HostCallContext
    public var sessionID: String
    /// Only what came after this point; nil for the whole conversation.
    public var afterSeq: UInt64?
    /// 0 to `maximumWaitSeconds`.
    public var waitSeconds: Int
    public init(context: HostCallContext, sessionID: String, afterSeq: UInt64? = nil, waitSeconds: Int = 0) {
        self.context = context
        self.sessionID = sessionID
        self.afterSeq = afterSeq
        self.waitSeconds = waitSeconds
    }
}

public enum ConversationState: String, Sendable, Hashable, Codable {
    /// A turn is going.
    case running
    /// It asked the user and waits for the answer.
    case waitingForApproval
    /// Its last turn finished; it waits for a message.
    case idle
    /// Closed, failed or stopped with the session host; it takes no more
    /// messages until the user reopens it.
    case ended
}

public struct ConversationMessage: Sendable, Hashable, Codable {
    public var seq: UInt64
    /// `assistant`, or `error` for a failure it reported.
    public var role: String
    public var text: String
    public init(seq: UInt64, role: String, text: String) {
        self.seq = seq
        self.role = role
        self.text = text
    }
}

public struct ConversationApproval: Sendable, Hashable, Codable {
    public var approvalID: String
    public var tool: String
    public var reason: String
    public init(approvalID: String, tool: String, reason: String) {
        self.approvalID = approvalID
        self.tool = tool
        self.reason = reason
    }
}

public struct ConversationReadToolResponse: Sendable, Hashable, Codable {
    public var sessionID: String
    public var title: String?
    public var state: ConversationState
    public var messages: [ConversationMessage]
    /// Approvals it waits on, which only the user can give.
    public var pendingApprovals: [ConversationApproval]
    /// Pass as after_seq to read on from here.
    public var lastSeq: UInt64
    /// The messages were cut at a bound; read again from `lastSeq` for the rest.
    public var truncated: Bool
    /// The wait ran out before the turn ended.
    public var timedOut: Bool
    public init(
        sessionID: String,
        title: String? = nil,
        state: ConversationState,
        messages: [ConversationMessage] = [],
        pendingApprovals: [ConversationApproval] = [],
        lastSeq: UInt64,
        truncated: Bool = false,
        timedOut: Bool = false,
    ) {
        self.sessionID = sessionID
        self.title = title
        self.state = state
        self.messages = messages
        self.pendingApprovals = pendingApprovals
        self.lastSeq = lastSeq
        self.truncated = truncated
        self.timedOut = timedOut
    }
}

/// A conversation call that did not happen, in words the model can act on.
public struct ConversationToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}
