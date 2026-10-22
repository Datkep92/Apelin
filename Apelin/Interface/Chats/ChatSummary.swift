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
    /// The reader named it (`rename(to:)`), and a title the agent suggests
    /// no longer replaces that name. Absent from older files.
    var isNamedByReader: Bool?
}

extension ChatSummary {
    /// Names the conversation as the reader typed it, for good. A name
    /// with nothing but spaces in it changes nothing; returns whether the
    /// name was taken.
    @discardableResult
    mutating func rename(to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        title = trimmed
        isNamedByReader = true
        return true
    }

    /// A title someone other than the reader suggests — the agent's `title`
    /// event, the first message's opening — taken unless the reader named
    /// the conversation.
    mutating func suggestTitle(_ suggestion: String) {
        guard isNamedByReader != true, !suggestion.isEmpty else { return }
        title = suggestion
    }
}
