import ApelinCore
import ApelinProtocol
import Foundation

struct ChatRecord: Codable, Sendable {
    var summary: ChatSummary
    var draft = ComposerDraft()
    var sessionID: String?
    var task: TaskHandle?
    /// Only ever appended to (`take`): the runtime's transcript of them reads
    /// on from the ones it has read (`ChatTranscriptCache`).
    var events: [TaskEvent] = []
    /// Whether this record's `events` have been read from disk. Runtime flag;
    /// absent in older files (defaults to false, and `hasEventsOnDisk` checks
    /// the events file).
    var eventsLoaded: Bool = false
    /// Messages sent and not yet echoed by the host, oldest first: shown at
    /// once, and kept on disk until their `prompt` or `queued` event comes
    /// back, so a kill mid-send loses none. Absent from older files.
    var sending: [ComposerDraft]?
    /// Set while the task of a reopened session replays the history
    /// `events` already hold (`reopen(as:)`). Absent from older files.
    var replay: SessionReplay?
    /// The model this conversation runs on: nil for an older conversation,
    /// which takes the reader's current one. Added per-conversation model
    /// support; absent from older files.
    var modelSelection: ComposerModelSelection?
    /// Where an automatic retry after a failure another model or key can
    /// answer stands — a spent allowance, or a key the provider refused.
    /// Named `rateLimitRetry` in older files, whose state is dropped; absent
    /// from files older still.
    var retryState: ModelRetryState?
}

/// An automatic retry after a failure another model or key can answer — a
/// model with a spent allowance, or a key the provider refused: the reader's
/// message sent again with the next candidate of `ModelCandidates.fallbackList`
/// — the same model on another configuration of the provider first, which is
/// another key — at most `ModelRetryPolicy.maximumRetries` times on its own.
/// Kept with the conversation so a relaunch remembers what is left of the list
/// and how many tries were spent.
struct ModelRetryState: Codable, Sendable, Equatable {
    /// Models left to try, in fallback order, the next one first: each is
    /// removed as it is sent. Empty means the reader is the only one who
    /// can ask again.
    var remaining: [ComposerModelSelection]
    /// The keys (by `ComposerModelSelection.retryKey`) that have already
    /// failed in this retry chain. They are never tried again, even after
    /// their cooldown — the reader's own Retry does not revive them.
    var triedKeys: Set<String> = []
    /// The text sent again, taken from the message the error answered. Kept
    /// for a state written before the message was read from the
    /// conversation's own events, which is what a retry sends.
    var text: String
    /// How many retries were already sent for this run.
    var attempts = 0
    /// Set while the run the error came from is still going: the next model
    /// is sent when it ends. Absent from older files.
    var awaitingTurn: Bool?
    /// What the failure was, as far as its wording says
    /// (`ModelRetrySignal.kind(of:)`): it decides whether an automatic retry
    /// runs at all and how long the candidate that failed is left alone.
    /// Absent from older files, and from a state whose failure named nothing.
    var kind: ModelFailureKind?
    /// The candidates that failed, each until the moment it may be tried
    /// again, by `ComposerModelSelection.retryKey` (`ModelCandidates`). An
    /// automatic retry steps over one still waiting; the reader's own Retry
    /// takes it anyway, since they asked.
    var cooldowns: [String: Date]?
}

/// The replay a reopened session's task starts with: every event of the
/// session again, renumbered and newly timed, before anything new. It ends
/// at the first user message or compaction the conversation has not seen:
/// Compact… reopens a stopped session too, with no message after it. It
/// also ends where the task does, when the task stops before getting that
/// far: its worker died, the host stopped, or a second open of the session
/// failed.
struct SessionReplay: Codable, Sendable {
    private static let userMessageKinds: Set<String> = ["prompt", "steer"]
    private static let compactionKind = "compactionStarted"

    /// How far the task has been read.
    var cursor = EventSeq.start
    /// The user messages still to come again: those with an id, and how many
    /// without one (a steer, or a message another conversation sent).
    private var messageIDs: Set<UUID> = []
    private var unnamedMessages = 0
    /// The compactions still to come again. Absent from older files, which
    /// have none.
    private var compactions: Int?

    /// The replay of a session whose history is `events`.
    init(of events: [TaskEvent]) {
        for event in events where Self.userMessageKinds.contains(event.kind) {
            if let id = ChatTranscript.userMessageID(of: event) {
                messageIDs.insert(id)
            } else {
                unnamedMessages += 1
            }
        }
        compactions = events.count { $0.kind == Self.compactionKind }
    }

    /// Whether `event` is still part of the replay, counting off the user
    /// message it repeats. The `state` a task ends with never is: the
    /// worker replays only the states an approval sets, so one that ends
    /// the task is this task's own end, and the turn ends on it as in a
    /// first task.
    mutating func replays(_ event: TaskEvent) -> Bool {
        if ChatTranscript.endsTask(event) {
            return false
        }
        if event.kind == Self.compactionKind {
            guard let remaining = compactions, remaining > 0 else { return false }
            compactions = remaining - 1
            return true
        }
        guard Self.userMessageKinds.contains(event.kind) else { return true }
        if let id = ChatTranscript.userMessageID(of: event) {
            return messageIDs.remove(id) != nil
        }
        guard unnamedMessages > 0 else { return false }
        unnamedMessages -= 1
        return true
    }
}

extension ChatRecord {
    /// `message` sent by the reader, shown at once from `sending` until the
    /// host echoes it, the composer emptied if it held that draft. Writing
    /// in a conversation is what moves it up the sidebar (`lastInteraction`).
    mutating func submit(_ message: ComposerDraft, at now: Date = Date()) {
        sending = (sending ?? []) + [message]
        if draft.id == message.id {
            draft = ComposerDraft()
        }
        summary.lastInteraction = now
        _ = summary.markRead()
    }

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

    /// The session is now `task`. One that is not the task `events` came
    /// from belongs to a reopened session, and starts by replaying the whole
    /// history under its own numbering; `events` already hold it, so `take`
    /// reads past that replay instead of showing it again. With no history
    /// there is nothing to read past: a first task's events are all new,
    /// an error before its first prompt included.
    mutating func reopen(as task: TaskHandle) {
        guard self.task != task else { return }
        self.task = task
        replay = events.isEmpty ? nil : SessionReplay(of: events)
    }

    /// Where reading the session's task goes on from.
    var cursor: EventSeq {
        replay?.cursor ?? events.last?.seq ?? .start
    }

    /// Adds the events of `batch` past the cursor, less a reopened task's
    /// replay, and returns them.
    mutating func take(_ batch: [TaskEvent]) -> [TaskEvent] {
        let fresh = batch.filter { $0.seq > cursor }
        guard var replay else {
            events += fresh
            return fresh
        }
        for (index, event) in fresh.enumerated() {
            guard replay.replays(event) else {
                self.replay = nil
                let taken = Array(fresh[index...])
                events += taken
                return taken
            }
            replay.cursor = event.seq
        }
        self.replay = replay
        return []
    }

    /// Where the end of the finished task `batch` answered for is, when this
    /// conversation read past it: the cursor is there, and its transcript
    /// still runs a turn (`isWorking`) though the task has ended. An earlier
    /// version read the `state` a reopened session's task ended with during
    /// its replay as part of the replay, and moved the cursor past it,
    /// where no attach brings it again. The host appends nothing after that
    /// `state`, so it is the task's last event, at `batch.lastSeq`. Nil
    /// when nothing is missing.
    func missedEnd(of batch: TaskEventBatch, isWorking: Bool) -> EventSeq? {
        guard isWorking, batch.finished, batch.lastSeq > .start, cursor >= batch.lastSeq else { return nil }
        return batch.lastSeq
    }

    /// Takes `end`, read again from the task, as the end `missedEnd` found
    /// at `seq`: that one event, once, which ends a replay still waiting.
    /// Nil, or anything but a `state` that ends the task at `seq`, is left
    /// out. Either way the row stops working, since the task has ended.
    /// Returns whether it took the event.
    @discardableResult
    mutating func takeMissedEnd(_ end: TaskEvent?, at seq: EventSeq) -> Bool {
        summary.isWorking = false
        guard let end, end.seq == seq, ChatTranscript.endsTask(end), events.last != end else { return false }
        replay = nil
        events.append(end)
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
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        var result: [ChatRecord] = []
        for url in urls {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let path = CanonicalPath.resolve(url.path),
                  CanonicalPath.isCanonical(path, inside: directoryPath)
            else { continue }
            var record = try JSONDecoder().decode(ChatRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let id = record.summary.id
            let eventsURL = directory.appendingPathComponent(id.uuidString + ".events.json")
            // Migration from the old single-file format: move events out.
            if !record.events.isEmpty {
                if !FileManager.default.fileExists(atPath: eventsURL.path) {
                    let data = try JSONEncoder().encode(record.events)
                    try data.write(to: eventsURL, options: .atomic)
                }
                record.events = []
                record.eventsLoaded = false
                let summaryData = try JSONEncoder().encode(record)
                try summaryData.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: eventsURL.path) {
                record.eventsLoaded = false
            } else {
                record.eventsLoaded = true
            }
            result.append(record)
        }
        return result
    }

    func save(_ record: ChatRecord, revision: Int) throws {
        let id = record.summary.id
        guard revision > (revisions[id] ?? -1) else { return }
        let directory = folder.root.appendingPathComponent("Chats")
        try folder.makeLevels(to: directory)
        var summaryRecord = record
        summaryRecord.events = []
        let summaryData = try JSONEncoder().encode(summaryRecord)
        try summaryData.write(to: directory.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        let eventsURL = directory.appendingPathComponent(id.uuidString + ".events.json")
        if record.eventsLoaded {
            if record.events.isEmpty {
                try? FileManager.default.removeItem(at: eventsURL)
            } else {
                let eventsData = try JSONEncoder().encode(record.events)
                try eventsData.write(to: eventsURL, options: .atomic)
            }
        }
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
        try? FileManager.default.removeItem(
            at: folder.root.appendingPathComponent("Chats/" + id.uuidString + ".events.json"),
        )
        revisions[id] = Int.max
    }

    func loadEvents(for id: UUID) throws -> [TaskEvent] {
        let url = folder.root.appendingPathComponent("Chats/" + id.uuidString + ".events.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TaskEvent].self, from: data)
    }

    func hasEventsFile(for id: UUID) -> Bool {
        let url = folder.root.appendingPathComponent("Chats/" + id.uuidString + ".events.json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    func removeEvents(for id: UUID) throws {
        try? FileManager.default.removeItem(at: folder.root.appendingPathComponent("Chats/" + id.uuidString + ".events.json"))
    }
}
// Appended during CI fix to ensure ComposerModelSelection is in a registered source file.

import ApelinProtocol
import Foundation

extension Notification.Name {
    static let composerModelSelectionChanged = Notification.Name("wiki.qaq.apelin.composerModelSelectionChanged")
}

/// The model every composer sends with, restored before the catalog loads.
/// Each control of the model row keeps a default of its own: this is the
/// model's, with the catalog's last word on what it offers; the reader's
/// effort and speed are `ComposerModelPreferences`, which only the reader's
/// pick changes. A model that does not offer them is sent the nearest it
/// does, and a later model that offers them gets them back.
struct ComposerModelSelection: Codable, Equatable {
    var provider: AgentProvider
    var model: String
    /// Which saved configuration of `provider` the model belongs to: nil
    /// for its first one, as before configurations had ids. Two Anthropic
    /// API keys pick their models apart through this.
    var profileID: String?
    /// The last catalog snapshot, so the effort control also restores offline.
    var supportedEfforts: [AgentReasoningEffort]
    /// The tiers the model offers, from the same snapshot; absent in a
    /// selection saved before there were any.
    var supportedTiers: [AgentServiceTier]?
    /// The effort sent: the reader's where the model offers it, else High,
    /// else its strongest; nil for a model that offers none.
    var effort: AgentReasoningEffort? {
        if let chosen = ComposerModelPreferences.effort, supportedEfforts.contains(chosen) {
            return chosen
        }
        return supportedEfforts.contains(.high) ? .high : supportedEfforts.last
    }

    /// The tier sent: the reader's where the model offers it, else the
    /// standard one (nil).
    var tier: AgentServiceTier? {
        ComposerModelPreferences.tier.flatMap { (supportedTiers ?? []).contains($0) ? $0 : nil }
    }

    static var current: Self? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        set {
            ComposerModelPreferences.adoptLegacyPicks()
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    fileprivate static let key = "composer.modelSelection"
}

/// The reader's own picks on the effort and Speed controls, each kept
/// under its own key whatever model is chosen and whatever its catalog
/// lists, so a model that lacks one, or a catalog that briefly says
/// nothing, never takes it away.
enum ComposerModelPreferences {
    private static let effortKey = "composer.reasoningEffort"
    private static let tierKey = "composer.serviceTier"
    /// What `tierKey` holds for a reader who picked Standard, so the pick
    /// is told apart from a key never written.
    private static let standardTier = "standard"

    /// Nil until the reader picks one.
    static var effort: AgentReasoningEffort? {
        get {
            UserDefaults.standard.string(forKey: effortKey).flatMap(AgentReasoningEffort.init(rawValue:))
                ?? legacy?.effort
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: effortKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// Nil is the standard tier.
    static var tier: AgentServiceTier? {
        get {
            guard let saved = UserDefaults.standard.string(forKey: tierKey) else { return legacy?.tier }
            return AgentServiceTier(rawValue: saved)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? standardTier, forKey: tierKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// The picks a selection saved before these keys existed held itself;
    /// read until the selection is written again, which moves them here.
    private struct Legacy: Decodable {
        var effort: AgentReasoningEffort?
        var tier: AgentServiceTier?
    }

    private static var legacy: Legacy? {
        UserDefaults.standard.data(forKey: ComposerModelSelection.key)
            .flatMap { try? JSONDecoder().decode(Legacy.self, from: $0) }
    }

    /// Before a new selection replaces one that still holds the picks.
    fileprivate static func adoptLegacyPicks() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: effortKey) == nil || defaults.object(forKey: tierKey) == nil,
              let legacy
        else { return }
        if defaults.object(forKey: effortKey) == nil, let effort = legacy.effort {
            defaults.set(effort.rawValue, forKey: effortKey)
        }
        if defaults.object(forKey: tierKey) == nil {
            defaults.set(legacy.tier?.rawValue ?? standardTier, forKey: tierKey)
        }
    }
}
