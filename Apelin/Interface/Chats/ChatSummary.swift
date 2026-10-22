import Foundation

/// One conversation as the sidebar lists it.
struct ChatSummary: Hashable, Codable, Sendable {
    var id = UUID()
    var title: String
    /// When it was last active: the day it is listed under.
    var updated: Date
    /// The project it belongs to; nil for a temporary conversation.
    var projectName: String?
    /// Listed above the days, until it is unpinned.
    var isPinned = false
    /// Whether this conversation has a running turn.
    var isWorking = false
}
