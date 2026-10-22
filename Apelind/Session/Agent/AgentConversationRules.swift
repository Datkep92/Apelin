import ApelinCore
import ApelinProtocol
import Foundation

/// What an agent may do with its project's other conversations
/// (`AgentConversations`), decided from the host's own session table and
/// never from what the agent says. AgentHandler applies these to a request
/// from `Caller.worker(.agent, instance:)`, whose instance is the caller's
/// session; the app's requests pass through unchanged, except that a
/// prompt's `fromSessionID` is the host's to write.
enum AgentConversationRules {
    /// The longest title the host keeps for a conversation.
    static let maximumTitleLength = 80

    /// The open request the host sends for an agent's `agentOpen`: the
    /// opener's own project under its current approval mode, with the
    /// prompt, title, provider, model and effort it asked for, and nothing
    /// else of its own — no session to reopen, no temporary workspace, no
    /// headless close.
    static func childOpen(_ open: AgentOpenRequest, opener: AgentSessionTable.Entry) throws -> AgentOpenRequest {
        guard !opener.project.isTemporary else {
            throw ApelinError(.denied, "only a project's conversations open other conversations")
        }
        guard opener.depth < AgentConversations.maximumDepth else {
            throw ApelinError(
                .denied,
                "a conversation another agent opened \(opener.depth) deep cannot open more; do the work here",
            )
        }
        guard let prompt = open.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApelinError(.badRequest, "a conversation an agent opens starts with a prompt")
        }
        return AgentOpenRequest(
            projectID: opener.project.id,
            projectName: opener.project.name,
            provider: open.provider,
            model: open.model,
            approvalMode: opener.mode,
            reasoningEffort: open.reasoningEffort,
            prompt: prompt,
            title: title(open.title),
        )
    }

    /// The prompt the host hands the target for an agent's `agentPrompt`:
    /// the text alone, as the user's message marked with the sender, with
    /// none of the sender's mode, model or files.
    static func childPrompt(
        _ prompt: AgentPromptRequest,
        sender: AgentSessionTable.Entry,
        target: AgentSessionTable.Entry?,
        descriptorCount: Int,
    ) throws -> AgentPromptRequest {
        guard descriptorCount == 0, prompt.attachments?.isEmpty ?? true else {
            throw ApelinError(.badRequest, "a message from another conversation carries no files")
        }
        guard let target else {
            throw ApelinError(.notFound, "no conversation \(prompt.sessionID)")
        }
        guard target.sessionID != sender.sessionID else {
            throw ApelinError(.badRequest, "a conversation does not send messages to itself")
        }
        guard target.project == sender.project else {
            throw ApelinError(.denied, "conversation \(target.sessionID) is not in this project")
        }
        guard !prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ApelinError(.badRequest, "the message is empty")
        }
        return AgentPromptRequest(sessionID: target.sessionID, text: prompt.text, fromSessionID: sender.sessionID)
    }

    /// The app's prompt is the user's own: whatever `fromSessionID` it
    /// carries is dropped.
    static func appPrompt(_ prompt: AgentPromptRequest) -> AgentPromptRequest {
        var prompt = prompt
        prompt.fromSessionID = nil
        return prompt
    }

    /// An agent aborts or closes only a conversation it opened.
    static func mayStop(_ target: AgentSessionTable.Entry?, caller: AgentSessionTable.Entry, sessionID: String) throws {
        guard let target else {
            throw ApelinError(.notFound, "no conversation \(sessionID)")
        }
        guard target.parentSessionID == caller.sessionID else {
            throw ApelinError(.denied, "an agent stops only the conversations it opened")
        }
    }

    /// An agent reads only the task of a conversation of its own project.
    static func mayRead(_ taskID: TaskID, target: AgentSessionTable.Entry?, caller: AgentSessionTable.Entry) throws {
        guard let target, target.project == caller.project else {
            throw ApelinError(.denied, "task \(taskID) is not a conversation of this project")
        }
    }

    /// `conversationOpened` on the opener's task: {sessionID, task, title?,
    /// prompt}, from which the app adopts the conversation.
    static func openedEvent(sessionID: String, task: TaskHandle, title: String?, prompt: String) -> JSONValue {
        var payload: [String: JSONValue] = [
            "sessionID": .string(sessionID),
            "task": .object(["taskID": .string(task.taskID.rawValue), "kind": .string(task.kind.rawValue)]),
            "prompt": .string(prompt),
        ]
        if let title {
            payload["title"] = .string(title)
        }
        return .object(payload)
    }

    /// One line, trimmed and bounded; nil when nothing is left.
    static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maximumTitleLength))
    }
}
