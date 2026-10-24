import ApelinProtocol
import Foundation

/// The transcripts the runtime keeps, one per conversation, each built again
/// only when what it shows changed. Building one reads every event the
/// conversation has, and one is asked for after every change to any
/// conversation: each streamed batch, of this one or of another streaming
/// beside it.
///
/// Kept for the conversations being followed and for the last other one
/// built, the page's, so browsing does not keep every history twice.
struct ChatTranscriptCache {
    private var entries: [UUID: Entry] = [:]
    private var unfollowed: UUID?

    /// `record`'s transcript: the one built before while it still holds,
    /// else a new one. `isFollowed` says which conversations a reader
    /// follows; `conversationTitle` and `attachment` are the transcript's.
    mutating func transcript(
        of record: ChatRecord,
        isFollowed: (UUID) -> Bool,
        conversationTitle: (String) -> String?,
        attachment: (AgentAttachment) -> ComposerAttachment?,
    ) -> ChatTranscript {
        let id = record.summary.id
        let sending = (record.sending ?? []).map(Entry.Sent.init)
        if let entry = entries[id], entry.holds(record, sending: sending, conversationTitle: conversationTitle) {
            return entry.transcript
        }
        var senderTitles: [String: String?] = [:]
        var transcript = ChatTranscript(
            events: record.events,
            sending: record.sending ?? [],
            conversationTitle: { sessionID in
                let title = conversationTitle(sessionID)
                senderTitles.updateValue(title, forKey: sessionID)
                return title
            },
            attachment: attachment,
        )
        if let shown = entries[id]?.transcript.messages {
            transcript.messages = Self.reusing(shown, in: transcript.messages)
        }
        if !isFollowed(id) {
            unfollowed = id
        }
        entries = entries.filter { isFollowed($0.key) || $0.key == unfollowed }
        entries[id] = Entry(
            transcript: transcript,
            eventCount: record.events.count,
            sending: sending,
            senderTitles: senderTitles,
        )
        return transcript
    }

    mutating func remove(_ id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// `rows`, each one equal to its row in `shown` taken from there. The
    /// page compares the rows it shows with new ones and the list diffs them
    /// again; a row that is the very value shown before compares by its
    /// storage, where one built anew is read again text by text.
    static func reusing(_ shown: [ChatMessage], in rows: [ChatMessage]) -> [ChatMessage] {
        let earlier = Dictionary(shown.map { ($0.id, $0) }) { first, _ in first }
        return rows.map { row in
            guard let earlier = earlier[row.id], earlier == row else { return row }
            return earlier
        }
    }

    /// A transcript and what it was built from.
    private struct Entry {
        /// A message being sent, as its row shows it.
        struct Sent: Equatable {
            let id: UUID
            let text: String
            let attachments: [UUID]

            init(_ draft: ComposerDraft) {
                id = draft.id
                text = draft.text
                attachments = draft.attachments.map(\.id)
            }
        }

        var transcript: ChatTranscript
        /// How many of the record's events it shows; they are only ever
        /// appended to (`ChatRecord.take`).
        var eventCount: Int
        var sending: [Sent]
        /// The titles it names other conversations' messages by, by session
        /// ID, as it read them; a rename there shows here.
        var senderTitles: [String: String?]

        /// Whether it still shows `record`, whose messages on their way are
        /// `sending`, as a transcript built now would.
        func holds(_ record: ChatRecord, sending: [Sent], conversationTitle: (String) -> String?) -> Bool {
            eventCount == record.events.count && self.sending == sending
                && senderTitles.allSatisfy { conversationTitle($0.key) == $0.value }
        }
    }
}
