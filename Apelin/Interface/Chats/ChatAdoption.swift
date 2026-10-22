import ApelinCore
import ApelinProtocol
import Foundation

/// Conversations an agent opened (`AgentConversations`), taken in as the
/// app's own: listed in the opener's project, followed like any other, and
/// never selected on their own.
enum ChatAdoption {
    /// The record for a `conversationOpened` event on `parent`'s task, or
    /// nil when a record already has that session or the event names none.
    static func record(
        opened payload: JSONValue?,
        parent: ChatRecord,
        records: [ChatRecord],
        now: Date = Date(),
    ) -> ChatRecord? {
        guard let project = parent.summary.projectName,
              let sessionID = payload?["sessionID"]?.stringValue, UUID(uuidString: sessionID) != nil,
              let task = try? payload?["task"]?.decode(TaskHandle.self), task.kind == .agent,
              !records.contains(where: { $0.sessionID == sessionID })
        else { return nil }
        let title = title(payload?["title"]?.stringValue, prompt: payload?["prompt"]?.stringValue)
        return ChatRecord(
            summary: ChatSummary(title: title, updated: now, projectName: project, isWorking: true),
            sessionID: sessionID,
            task: task,
        )
    }

    /// The record for a running session an agent opened while the app was
    /// not following its opener, or nil when it has one already, has ended,
    /// or its opener has no record to take the project from.
    static func record(session: AgentSessionSummary, records: [ChatRecord]) -> ChatRecord? {
        guard let parentID = session.parentSessionID, !session.state.isTerminal,
              !records.contains(where: { $0.sessionID == session.sessionID }),
              let parent = records.first(where: { $0.sessionID == parentID }),
              let project = parent.summary.projectName
        else { return nil }
        return ChatRecord(
            summary: ChatSummary(
                title: title(session.title, prompt: nil),
                updated: session.updatedAt,
                projectName: project,
            ),
            sessionID: session.sessionID,
            task: session.task,
        )
    }

    /// The opener's title, else the first line of the prompt, as the
    /// sidebar shows a conversation the user started.
    static func title(_ title: String?, prompt: String?) -> String {
        for text in [title, prompt] {
            let line = text?.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
        }
        return String(localized: "New Chat")
    }
}
