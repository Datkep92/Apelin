import ApelinCore
import ApelinProtocol
import Foundation

/// An agent's `feedbackSend` (apelin_feedback_send, owner, 2026-10-29): a
/// public issue on `FeedbackRules.repository` under the user's GitHub
/// account, so, like a push, it asks under Confirm every time. Each one
/// spends an approval the app gave this session whose own
/// `approvalRequested` names exactly that issue (`detail.feedback`
/// {repository, title, body}), once, never for the session; Relaxed and
/// Full send it as they push. apelin-environment checks the text again
/// (`FeedbackRules`) and writes the footer itself.
enum AgentFeedbackRules {
    static let detailKey = "feedback"

    /// Whether `asked`, the payload of one of the session's own
    /// `approvalRequested` events, approves exactly this issue.
    static func covers(_ feedback: FeedbackSendRequest, asked: JSONValue) -> Bool {
        guard asked["tool"]?.stringValue == AgentToolName.feedbackSend.rawValue, let detail = asked["detail"]?[detailKey] else {
            return false
        }
        return detail["repository"]?.stringValue == FeedbackRules.repository
            && detail["title"]?.stringValue == feedback.title
            && detail["body"]?.stringValue == feedback.body
    }

    /// Nil when the session may send it, else why not; under Confirm the
    /// approval that covers it is spent.
    static func authorize(_ feedback: FeedbackSendRequest, session: String?, registry: TaskRegistry) async -> ApelinError? {
        guard let session, let entry = await AgentSessionTable.shared.entry(session) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard entry.mode.asks else { return nil }
        guard await AgentApprovals.spend(entry: entry, registry: registry, covers: { covers(feedback, asked: $0) }) else {
            return ApelinError(
                .denied,
                "approval required: the user has not approved posting this issue on \(FeedbackRules.repository)",
            )
        }
        return nil
    }
}
