import ApelinCore
import ApelinProtocol
import Foundation

struct ChatRecord: Codable, Sendable {
    var summary: ChatSummary
    var draft = ComposerDraft()
    var sessionID: String?
    var task: TaskHandle?
    var events: [TaskEvent] = []
    /// Messages sent and not yet echoed by the host, oldest first: shown at
    /// once, and kept on disk until their `prompt` or `queued` event comes
    /// back, so a kill mid-send loses none. Absent from older files.
    var sending: [ComposerDraft]?
}

extension ChatRecord {
    /// Takes out of `sending` each message `events` echo, and returns it
    /// with the event that echoed it. A draft put back by
    /// `reclaimUnsent` that the host did take is emptied too, unless its
    /// text was changed since.
    mutating func takeEchoed(by events: [TaskEvent]) -> [(draft: ComposerDraft, event: TaskEvent)] {
        var echoed: [(draft: ComposerDraft, event: TaskEvent)] = []
        for event in events {
            guard let id = ChatTranscript.userMessageID(of: event) else { continue }
            if let index = sending?.firstIndex(where: { $0.id == id }), let draft = sending?.remove(at: index) {
                echoed.append((draft, event))
            }
            if draft.id == id, draft.text == event.payload?["text"]?.stringValue ?? "" {
                draft = ComposerDraft()
            }
        }
        if sending?.isEmpty == true {
            sending = nil
        }
        return echoed
    }

    /// A send that failed: the message leaves `sending`, and its draft
    /// returns if nothing was typed since and the host did not record it
    /// before failing (its event shows it then). Returns whether it did.
    mutating func takeBack(_ message: ComposerDraft) -> Bool {
        sending?.removeAll { $0.id == message.id }
        if sending?.isEmpty == true {
            sending = nil
        }
        let recorded = events.contains { ChatTranscript.userMessageID(of: $0) == message.id }
        guard !recorded, draft.text.isEmpty, draft.attachments.isEmpty else { return false }
        draft = message
        return true
    }

    /// After a relaunch, what is still in `sending` may never have reached
    /// the host, so it goes back to the draft, before anything typed after
    /// it. A lone message keeps its id: if the host did take it, sending it
    /// again is not a second message, and its echo empties the draft.
    mutating func reclaimUnsent() {
        _ = takeEchoed(by: events)
        guard let unsent = sending else { return }
        sending = nil
        let parts = (unsent + [draft]).filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
        if parts.count == 1, let only = parts.first {
            draft = only
        } else {
            draft = ComposerDraft(text: parts.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                  attachments: parts.flatMap(\.attachments))
        }
    }
}

/// Serial disk writes keep a slow earlier save from replacing a newer transcript.
actor ChatStore {
    private let folder: DataFolder
    private var revisions: [UUID: Int] = [:]

    init(folder: DataFolder) {
        self.folder = folder
    }

    func load() throws -> [ChatRecord] {
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        guard let directoryPath = CanonicalPath.resolve(directory.path) else { throw CocoaError(.fileReadNoSuchFile) }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let path = CanonicalPath.resolve(url.path),
                      CanonicalPath.isCanonical(path, inside: directoryPath)
                else { return nil }
                return try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            }
    }

    func save(_ record: ChatRecord, revision: Int) throws {
        let id = record.summary.id
        guard revision > (revisions[id] ?? -1) else { return }
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        try JSONEncoder().encode(record).write(
            to: directory.appendingPathComponent(id.uuidString + ".json"),
            options: .atomic,
        )
        revisions[id] = revision
    }

    func remove(_ id: UUID) throws {
        do {
            try FileManager.default.removeItem(
                at: folder.root.appendingPathComponent("Chats/" + id.uuidString + ".json"),
            )
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Deleting before the first queued save is also a successful delete.
        }
        revisions[id] = Int.max
    }
}
