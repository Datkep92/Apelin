import CoreGraphics
import Foundation

/// How far the conversation page follows a turn's output: to the newest
/// content, until the turn's own message reaches the top of the visible
/// area. At most a page, so a fast reply never scrolls past the reader.
enum TurnFollowing {
    /// The message a turn starts with: the newest user message a run has
    /// taken, or one just sent to an idle conversation. A message waiting
    /// for a running turn starts none yet.
    static func turnMessage(in rows: [ChatMessage]) -> UUID? {
        rows.last { $0.role == .user && !$0.isQueued }?.id
    }

    /// Where following moves the list from `offset`: toward `latest`, the
    /// offset that shows the newest content, but no further than puts
    /// `messageTop` (the turn's message, in content coordinates) at
    /// `topInset` below the list's top edge, and never back up. `reachesTop`
    /// once the message is there: the turn is followed no further.
    static func step(
        offset: CGFloat,
        latest: CGFloat,
        messageTop: CGFloat,
        topInset: CGFloat,
    ) -> (offset: CGFloat, reachesTop: Bool) {
        let limit = messageTop - topInset
        return (max(offset, min(latest, limit)), latest >= limit)
    }
}
