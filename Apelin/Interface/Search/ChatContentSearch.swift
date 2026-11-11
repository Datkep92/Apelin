import ApelinProtocol
import Foundation

/// The words a conversation holds that the reader is looking for, when the
/// words are not in its name: the sidebar's search shows the conversations
/// whose title has them and, beside those, the ones that said them
/// (`SidebarController.matches`).
///
/// A conversation's words are its events, which the sidebar does not keep in
/// memory (`ChatRuntime.loadEventsIfNeeded` reads them when one is opened):
/// the runtime reads one conversation at a time for a search and keeps
/// nothing, so a search costs a read per conversation and not a history in
/// memory for each.
enum ChatContentSearch {
    /// Where a conversation holds the words.
    struct Hit: Equatable, Sendable {
        /// The line the words sit in, cut and marked at both ends
        /// (`TextSearch.line`): what the row shows under the name.
        var line: String
    }

    /// The events whose words a search reads: what was said, thought or went
    /// wrong. Tool calls and their results are left out on purpose — a path or
    /// a command repeated in a hundred conversations would bring them all into
    /// a search, and the reader has the trace panel for that.
    private static let contentKinds: Set<String> = [
        "prompt", "steer", "queued",
        "text", "message", "thinking",
        "error", "compactionFinished",
    ]

    /// Where an event keeps its words, in the order a reader would look for
    /// them: what a message says, what an error said, what a compaction kept.
    private static let contentKeys = ["text", "message", "summary"]

    /// The first line of `events` holding `query`, nil when none does.
    ///
    /// Reading events until a match means the oldest one answers first, which
    /// is also what `TextSearch.line` promises for a single text.
    static func hit(_ query: String, in events: [TaskEvent]) -> Hit? {
        guard !query.isEmpty else { return nil }
        for event in events where contentKinds.contains(event.kind) {
            guard let payload = event.payload else { continue }
            for key in contentKeys {
                guard let words = payload[key]?.stringValue, !words.isEmpty else { continue }
                guard let line = TextSearch.line(of: words, holding: query) else { continue }
                return Hit(line: line)
            }
        }
        return nil
    }
}
