import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import os
import UniformTypeIdentifiers

/// Owns chat history, drafts and live sessions independently of the selected page.
@MainActor
final class ChatRuntime {
    private let log = Logger(subsystem: "wiki.qaq.apelin", category: "chat")
    var onChange: (() -> Void)?
    /// The saved conversations could not be read.
    var onError: ((Error) -> Void)?
    /// A conversation could not be written; it goes on in memory and is
    /// written again with the next save that gets through.
    var onSaveFailure: ((Error) -> Void)?
    /// A save got through after one had failed.
    var onSaveRecovered: (() -> Void)?
    /// A conversation's draft was put back from outside the composer.
    var onDraftRestored: ((UUID) -> Void)?
    /// Queued messages a stopped run never took went back to a
    /// conversation's composer, which the reader has yet to be told.
    var onUnsentReturned: ((UUID, DroppedMessages.Returned) -> Void)?
    /// Builds an agent ran completed, counted once each from the events a
    /// conversation had not read before (`CompletedBuilds`).
    var onBuildsCompleted: ((Int) -> Void)?
    private(set) var isLoaded = false
    /// The conversation the reader is looking at, nil while they look at
    /// none (`RootInterfaceController.syncViewedChat`). A reply that comes
    /// while another is looked at, or none, leaves it unread; looking at
    /// one reads it (`ChatUnread`).
    var viewedChat: UUID? {
        didSet {
            guard let viewedChat, viewedChat != oldValue else { return }
            var changedView = false
            if records[viewedChat]?.summary.markRead() == true { changedView = true }
            if records[viewedChat]?.summary.markCompletedViewed() == true { changedView = true }
            if changedView { changed(viewedChat) }
        }
    }
    /// Chats whose cut turn is taken up again by itself — when the app comes
    /// back, and when the background service answers again after it was
    /// killed — at most this many: each one replays its conversation's
    /// history into a new session, which the background service then holds.
    /// Every other chat is taken up when the user opens it — nothing is lost
    /// by waiting.
    static let maximumCutTurnResumes = 3

    /// The saved conversations have been checked against the host's live
    /// sessions once: what says working is working.
    private(set) var isReconciled = false
    private var reconciliationTask: Task<Void, Never>?
    private var loadingEvents: [UUID: Task<Void, Never>] = [:]
    private(set) var records: [UUID: ChatRecord] = [:]
    private let store = ChatStore(folder: .app)
    private var revision = 0
    private var readers: [UUID: Task<Void, Never>] = [:]
    /// Conversations whose cut turn is being taken up again while the
    /// background service answers again, and the ones the reader stopped
    /// itself, which are left as they are.
    private var resumingCutTurn: Set<UUID> = []
    private var stoppedChats: Set<UUID> = []
    /// Cut turns taken up again by themselves this launch, capped by
    /// `maximumCutTurnResumes`.
    private var cutTurnResumes = 0
    /// The plan each conversation is on, read from its events and from the
    /// host (`ChatPlan`). Kept here rather than in the saved conversation:
    /// the session has it, and reads it back itself, so the app asks again
    /// instead of keeping a second copy that could be older than the
    /// session's.
    private(set) var plans: [UUID: AgentPlan] = [:]
    private var opening: [UUID: Task<AgentOpenResponse, Error>] = [:]
    private var attachmentCache: [String: ComposerAttachment] = [:]
    private var transcripts = ChatTranscriptCache()
    /// Conversations whose latest state is in memory only.
    private var unsaved: Set<UUID> = []
    /// Conversations being written, and those changed again meanwhile. A
    /// conversation is written once at a time and then once more with what
    /// it holds by then, so one that streams faster than it can be written
    /// queues no save, nor a copy of its whole history, per batch.
    private var saving: Set<UUID> = []
    private var savesPending: Set<UUID> = []
    /// Pending saves that go as soon as the write under way ends: a turn
    /// began or ended, or the reader changed something.
    private var savesUrgent: Set<UUID> = []
    /// When each conversation's last write ended. A streamed or typed
    /// change waits until `saveInterval` after it, so a long history is
    /// written at most once in that time, and a write that took longer
    /// pushes the next one back as far.
    private var savedAt: [UUID: ContinuousClock.Instant] = [:]
    /// Saves waiting for their interval, by conversation.
    private var savesDeferred: [UUID: Task<Void, Never>] = [:]
    /// Called once no conversation is being written (`saveNow`).
    private var savesDrained: [() -> Void] = []
    private static let saveInterval: Duration = .seconds(3)
    /// Who waits for a conversation's compaction to end, by conversation.
    private var compactions: [UUID: CheckedContinuation<AgentCompactionResult, Error>] = [:]
    /// Conversations whose retry is being answered right now. Two
    /// errors of one run, read in two batches, would otherwise each look up
    /// the models to fall back to and each write the state: the slower one
    /// would put back the model and the try the faster one spent.
    private var answeringRetryableFailure: Set<UUID> = []

    var summaries: [ChatSummary] {
        records.values.map(\.summary)
    }

    /// Reads every saved conversation. An untouched one left by an earlier
    /// launch is dropped, unless it is `selected`, the one to show again.
    func load(keeping selected: UUID?) async {
        guard !isLoaded else { return }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            log.info("startup: load start")
            async let storedRecords = try store.load()
            async let liveSessions = (try? ApelinService.app.agentList().sessions) ?? []
            let loaded = try await storedRecords
            log.info("startup: store.load done n=\(loaded.count) in \(String(describing: clock.now - start))")
            for var record in loaded {
                let unsent = record.sending != nil
                if unsent {
                    // Events must be loaded before reclaimUnsent: takeEchoed
                    // reads them to decide which unsent messages the host took.
                    let id = record.summary.id
                    let url = DataFolder.app.root.appendingPathComponent("Chats/\(id.uuidString).events.json")
                    if let data = try? Data(contentsOf: url),
                       let events = try? JSONDecoder().decode([TaskEvent].self, from: data) {
                        record.events = events
                        record.eventsLoaded = true
                    } else if !FileManager.default.fileExists(atPath: url.path) {
                        record.eventsLoaded = true
                    }
                }
                record.reclaimUnsent()
                records[record.summary.id] = record
                if unsent {
                    persist(record.summary.id, urgent: true)
                }
            }
            for record in records.values where isUntouched(record) && record.summary.id != selected {
                try? await removeRecord(record.summary.id)
                if record.summary.projectName == nil {
                    rmdir(DataFolder.app.root.appendingPathComponent("Temporary/" + record.summary.id.uuidString).path)
                }
            }
            await forget(DeletedProjects.gone(from: summaries, listed: DeletedProjects.listing(in: .app)))
            log.info("startup: cleanup + forget done in \(String(describing: clock.now - start))")
            isLoaded = true
            onChange?()
            log.info("startup: isLoaded in \(String(describing: clock.now - start))")

            let live = await liveSessions
            reconciliationTask = Task { @MainActor in
                let reconcileStart = clock.now
                log.info("startup: reconcile start")
                for record in self.records.values {
                    let needsEvents = record.summary.isWorking || live.contains { $0.sessionID == record.sessionID }
                    if needsEvents { await self.loadEventsIfNeeded(record.summary.id) }
                    if let session = live.first(where: { $0.sessionID == record.sessionID }) {
                        self.records[record.summary.id]?.reopen(as: session.task)
                        self.follow(record.summary.id, task: session.task)
                    } else if record.summary.isWorking {
                        // Nothing behind the app is running for this chat: the
                        // turn it was in the middle of was cut short when the
                        // background service stopped. Opening the conversation
                        // takes that turn up again where it stopped — the agent
                        // side sends the same message instead of losing it —
                        // and the row it is owed stays the one already in the
                        // transcript. It is not working until then.
                        self.records[record.summary.id]?.summary.isWorking = false
                        self.changed(record.summary.id)
                        if self.cutTurnResumes < Self.maximumCutTurnResumes {
                            if (try? await self.open(record.summary.id)) != nil {
                                self.cutTurnResumes += 1
                                log.info("reconcile: resumed a cut turn")
                            } else {
                                // the service is not answering yet: ask again
                                // as soon as it does
                                self.resumeCutTurnWhenServiceReturns(record.summary.id)
                            }
                        }
                    }
                }
                self.isReconciled = true
                self.onChange?()
                log.info("startup: reconcile done in \(String(describing: clock.now - reconcileStart))")
                for session in live {
                    self.adopt(ChatAdoption.record(session: session, records: Array(self.records.values)))
                }
                log.info("startup: adopt done in \(String(describing: clock.now - start))")
            }
        } catch { onError?(error) }
    }

    /// Lists and follows a conversation an agent opened, leaving the
    /// selection where it is.
    private func adopt(_ record: ChatRecord?) {
        guard let record, let task = record.task else { return }
        records[record.summary.id] = record
        changed(record.summary.id)
        follow(record.summary.id, task: task)
    }

    /// Lists and follows a session an `apelin://` link named that had no
    /// row (`ChatLinkTarget`), and returns its row.
    func adoptLinked(_ record: ChatRecord) -> ChatSummary? {
        guard !records.values.contains(where: { $0.sessionID == record.sessionID }) else { return nil }
        adopt(record)
        return records[record.summary.id]?.summary
    }

    /// A conversation to start in `project`: its untouched one, `current`
    /// first, brought to now, or else a new one.
    func newChat(project: String?, preferring current: UUID?) -> ChatSummary {
        let untouched = records.values.filter { $0.summary.projectName == project && isUntouched($0) }
        let reused = untouched.first { $0.summary.id == current }
            ?? untouched.max { $0.summary.lastInteraction < $1.summary.lastInteraction }
        let summary = reused?.summary ?? ChatSummary.untitled(lastInteraction: Date(), projectName: project)
        if reused == nil {
            records[summary.id] = ChatRecord(summary: summary)
        }
        records[summary.id]?.summary.lastInteraction = Date()
        changed(summary.id)
        return records[summary.id]?.summary ?? summary
    }

    /// Nothing sent, typed or attached, no session opening, not pinned and
    /// not named: a row that holds nothing but its place.
    private func isUntouched(_ record: ChatRecord) -> Bool {
        let hasEvents = record.eventsLoaded ? !record.events.isEmpty : eventsFileExists(for: record.summary.id)
        return !hasEvents && record.sessionID == nil && record.task == nil && opening[record.summary.id] == nil
            && record.sending == nil && record.draft.text.isEmpty && record.draft.attachments.isEmpty
            && !record.summary.isPinned && record.summary.isNamedByReader != true
    }

    private func eventsFileExists(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: DataFolder.app.root.appendingPathComponent("Chats/\(id.uuidString).events.json").path)
    }

    func loadEventsIfNeeded(_ id: UUID) async {
        guard let record = records[id], !record.eventsLoaded else { return }
        if let task = loadingEvents[id] {
            await task.value
            return
        }
        let task = Task { @MainActor in
            do {
                let events = try await store.loadEvents(for: id)
                records[id]?.events = events
                records[id]?.eventsLoaded = true
                changed(id)
            } catch {
                onError?(error)
            }
            loadingEvents[id] = nil
        }
        loadingEvents[id] = task
        await task.value
    }

    func loadEventsSyncIfNeeded(_ id: UUID) {
        guard let record = records[id], !record.eventsLoaded else { return }
        let url = DataFolder.app.root.appendingPathComponent("Chats/\(id.uuidString).events.json")
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let events = try? JSONDecoder().decode([TaskEvent].self, from: data) {
                records[id]?.events = events
                records[id]?.eventsLoaded = true
            }
            // If decode fails, eventsLoaded stays false
        } else {
            records[id]?.eventsLoaded = true
        }
    }

    func hasEventsOnDisk(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        if record.eventsLoaded { return !record.events.isEmpty }
        return eventsFileExists(for: id)
    }

    /// Where `id`'s conversation holds `query` in what was said in it, nil
    /// when it does not: what the sidebar's search shows under a conversation
    /// whose name does not hold the words (`ChatContentSearch`).
    ///
    /// A conversation already open is answered from memory; any other is read
    /// from its file, and the reading is not kept — the sidebar searches as
    /// the reader types, and holding every conversation's words in memory is
    /// the start-up cost the events files were split off to avoid.
    func contentHit(_ query: String, in id: UUID) async -> ChatContentSearch.Hit? {
        guard !query.isEmpty else { return nil }
        if let record = records[id], record.eventsLoaded {
            return ChatContentSearch.hit(query, in: record.events)
        }
        guard let events = try? await store.loadEvents(for: id) else { return nil }
        return ChatContentSearch.hit(query, in: events)
    }

    func saveDraft(_ draft: ComposerDraft, for id: UUID) {
        records[id]?.draft = draft
        persist(id)
    }

    func togglePin(_ id: UUID) {
        records[id]?.summary.isPinned.toggle()
        changed(id)
    }

    /// `name` as the conversation's title from now on: the agent's titles
    /// no longer replace it (`ChatSummary.rename(to:)`).
    func rename(_ id: UUID, to name: String) {
        guard records[id]?.summary.rename(to: name) == true else { return }
        changed(id)
    }

    /// A user message is gone from the conversation: the events that carry
    /// it — a `prompt`, a `steer` or a `queued` one — leave the record, as
    /// does the draft of a message still on its way. The record saves
    /// (`changed`), so the transcript rebuilds from the events left behind.
    func deleteMessage(_ messageID: UUID, in chatID: UUID) {
        loadEventsSyncIfNeeded(chatID)
        guard var record = records[chatID] else { return }
        if var sending = record.sending {
            sending = sending.filter { $0.id != messageID }
            record.sending = sending.isEmpty ? nil : sending
        }
        record.events = record.events.filter { ChatTranscript.userMessageID(of: $0) != messageID }
        records[chatID] = record
        changed(chatID)
    }

    func delete(_ id: UUID) async throws {
        let session = records[id]?.sessionID
        try await closeSession(id)
        let isTemporary = records[id].map { $0.summary.projectName == nil } ?? false
        try await removeRecord(id)
        onChange?()
        // its banners would open a conversation that is no longer there
        ConversationNotices.shared.withdraw(session: session)
        // a temporary conversation's working folder, its files with it, once
        // the row is gone: a file it cannot remove leaves the folder behind,
        // never a row Delete can no longer take away
        if isTemporary {
            let folder = DataFolder.app
            try? await Task.detached { try folder.removeTemporaryFolder(of: id) }.value
        }
    }

    func deleteProject(_ name: String) async throws {
        let ids = records.values.filter { $0.summary.projectName == name }.map(\.summary.id)
        for id in ids {
            ConversationNotices.shared.withdraw(session: records[id]?.sessionID)
            try await closeSession(id)
        }
        let folder = DataFolder.app
        try await Task.detached { try folder.removeProject(named: name) }.value
        defer { onChange?() }
        for id in ids {
            try await removeRecord(id)
        }
    }

    /// Takes away the conversations of every project whose folder has gone
    /// from `Projects/` (`DeletedProjects`), as `deleteProject` takes them
    /// once it has removed the folder itself. Answers the projects gone.
    @discardableResult
    func forgetDeletedProjects() async -> Set<String> {
        guard isLoaded else { return [] }
        let gone = DeletedProjects.gone(from: summaries, listed: DeletedProjects.listing(in: .app))
        guard !gone.conversations.isEmpty else { return [] }
        await forget(gone)
        onChange?()
        return gone.projects
    }

    /// Their banners withdrawn, any session the host left open closed —
    /// an agent's deletion closed its own, so nothing waits on the host
    /// here —, and their histories removed; a history that cannot be
    /// removed is tried again with the next change.
    private func forget(_ gone: DeletedProjects.Gone) async {
        for id in gone.conversations {
            let session = records[id]?.sessionID
            ConversationNotices.shared.withdraw(session: session)
            if let session {
                Task { try? await ApelinService.app.agentClose(sessionID: session) }
            }
            try? await removeRecord(id)
        }
    }

    private func closeSession(_ id: UUID) async throws {
        // A send may still be opening the session when Delete is tapped.
        var sessionID = records[id]?.sessionID
        if let pending = opening[id], let opened = try? await pending.value {
            sessionID = opened.sessionID
        }
        guard let sessionID else { return }
        do { try await ApelinService.app.agentClose(sessionID: sessionID) }
        catch let error as ApelinError where error.code == .notFound {
            // A finished session or one lost with the host is already closed.
        }
    }

    private func removeRecord(_ id: UUID) async throws {
        loadingEvents[id]?.cancel()
        loadingEvents.removeValue(forKey: id)
        // Keep the in-memory row on disk failure, so Delete can be retried.
        try await store.remove(id)
        readers.removeValue(forKey: id)?.cancel()
        savesDeferred.removeValue(forKey: id)?.cancel()
        savedAt[id] = nil
        records.removeValue(forKey: id)
        transcripts.remove(id)
    }

    /// The conversation's rows, brought up to date only when its events, the
    /// messages it is sending, a sender's title or the turn's quiet changed
    /// (`ChatTranscriptCache`).
    func transcript(_ id: UUID) -> ChatTranscript {
        guard let record = records[id] else {
            return ChatTranscript(events: []) { _ in nil }
        }
        return transcripts.transcript(
            of: record,
            now: Date(),
            isFollowed: { readers[$0] != nil },
            conversationTitle: { title(ofSession: $0) },
        ) { [self] item in attachment(item, in: id) }
    }

    /// The title of the conversation `sessionID` is, which names a message
    /// its agent sent.
    private func title(ofSession sessionID: String) -> String? {
        records.values.first { $0.sessionID == sessionID }?.summary.displayTitle
    }

    /// A message's attachment, read from its file once and kept. One that
    /// cannot be read is tried again with the conversation's next change.
    private func attachment(_ item: AgentAttachment, in id: UUID) -> ComposerAttachment? {
        guard let path = attachmentPath(item, in: id) else { return nil }
        if let cached = attachmentCache[path] {
            return cached
        }
        guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 32 * 1024 * 1024, let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        let isText = item.mimeType.hasPrefix("text/")
            || UTType(mimeType: item.mimeType)?.conforms(to: .text) == true
        let file = ComposerAttachment(
            name: item.name,
            data: data,
            text: isText ? String(decoding: data.prefix(8192), as: UTF8.self) : nil,
            isImage: item.mimeType.hasPrefix("image/"),
        )
        attachmentCache[path] = file
        return file
    }

    /// Where a message's attachment is: by its canonical path, inside the
    /// conversation's project or temporary folder.
    private func attachmentPath(_ item: AgentAttachment, in id: UUID) -> String? {
        let root: URL = if let name = records[id]?.summary.projectName,
                           let project = DataFolder.app.project(named: name)
        {
            project
        } else {
            DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString)
        }
        let url = root.appendingPathComponent(item.path)
        guard let rootPath = CanonicalPath.resolve(root.path),
              let path = CanonicalPath.resolve(url.path), CanonicalPath.isCanonical(path, inside: rootPath)
        else { return nil }
        return path
    }

    /// Shows `draft` at once as `id`'s next message, under the draft's id,
    /// which the host's `prompt` or `queued` event echoes; that event's row
    /// takes its place. The returned task sends it: when the send fails, the
    /// message is taken out again and the draft put back in an empty
    /// composer before the task throws.
    func submit(_ draft: ComposerDraft, to id: UUID) -> Task<Void, Error> {
        guard records[id] != nil else { return Task {} }
        records[id]?.submit(draft)
        // The reader moved on: what an earlier message's failure left to try
        // is no longer theirs to answer.
        records[id]?.retryState = nil
        changed(id)
        return Task {
            do {
                try await send(draft, to: id)
            } catch {
                takeBack(draft, from: id)
                throw error
            }
        }
    }

    /// A send that failed: its row goes, and its draft returns to an empty
    /// composer (`ChatRecord.takeBack`).
    private func takeBack(_ draft: ComposerDraft, from id: UUID) {
        guard let restored = records[id]?.takeBack(draft) else { return }
        changed(id)
        if restored {
            onDraftRestored?(id)
        }
    }

    private func send(_ draft: ComposerDraft, to id: UUID) async throws {
        guard records[id] != nil else { return }
        // A message the reader sends now is a turn they want taken up again
        stoppedChats.remove(id)
        let opened = try await open(id)
        guard records[id] != nil else { return }
        var descriptors: [OwnedDescriptor] = []
        var inputs: [AgentInputAttachment] = []
        // only attachments need the disk: text still goes out when it is full
        let staging = DataFolder.app.root.appendingPathComponent("Chats/Uploads/" + UUID().uuidString)
        if !draft.attachments.isEmpty {
            try DataFolder.app.makeLevels(to: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in draft.attachments {
            guard descriptors.count < 8, file.data.count <= 32 * 1024 * 1024 else {
                throw ApelinError(.badRequest, String(localized: "Send up to 8 files, each no larger than 32 MB."))
            }
            let url = staging.appendingPathComponent(file.id.uuidString)
            try file.data.write(to: url, options: .atomic)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            inputs.append(AgentInputAttachment(
                descriptor: DescriptorSlot(index: descriptors.count),
                name: file.name,
                mimeType: file.isImage
                    ? imageMIME(file.data)
                    : (UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"),
            ))
            descriptors.append(OwnedDescriptor(adopting: fd))
        }
        let selection = records[id]?.modelSelection ?? ComposerModelSelection.current
        if records[id]?.modelSelection == nil, selection != nil {
            records[id]?.modelSelection = selection
            changed(id)
        }
        _ = try await ApelinService.app.send(
            AgentPromptRequest(
                sessionID: opened.sessionID,
                text: draft.text,
                messageID: draft.id,
                attachments: inputs,
                provider: selection?.provider,
                model: selection?.model,
                profileID: selection?.profileID,
                reasoningEffort: selection?.effort,
                serviceTier: selection?.tier,
                approvalMode: AgentPermissions.mode,
                asksBeforeScreen: AgentPermissions.asksBeforeScreen,
            ),
            descriptors: descriptors,
        )
        records[id]?.summary.nameAfterFirstMessage(text: draft.text, attachmentName: draft.attachments.first?.name)
        records[id]?.summary.isCompleted = false
        changed(id)
    }

    /// `ownerVerified`: the reader passed the device owner's check for this
    /// decision, which the host requires to approve a command as root.
    func approve(_ messageID: UUID, in id: UUID, decision: ApprovalDecision, ownerVerified: Bool? = nil) async throws {
        guard let sessionID = records[id]?.sessionID,
              let approvalID = transcript(id).approvalIDs[messageID]
        else { return }
        try await ApelinService.app.agentApprove(
            sessionID: sessionID,
            approvalID: approvalID,
            decision: decision,
            ownerVerified: ownerVerified,
        )
    }

    func stop(_ id: UUID) async throws {
        guard let sessionID = records[id]?.sessionID else { return }
        // The reader asked for this turn to end: a background service that
        // comes back afterwards does not take it up again.
        stoppedChats.insert(id)
        try await ApelinService.app.agentAbort(sessionID: sessionID)
    }

    /// Between runs only: a session to compact, nothing running, waiting
    /// for an approval or on its way to the host.
    func canCompact(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        return record.sessionID != nil && !record.summary.isWorking && (record.sending ?? []).isEmpty
            && opening[id] == nil && compactions[id] == nil
    }

    /// Compacts the conversation, and returns how it went once the session
    /// says so. Cancelled, it stops the compaction.
    func compact(_ id: UUID) async throws -> AgentCompactionResult {
        loadEventsSyncIfNeeded(id)
        let opened = try await open(id)
        // what the reader takes from here on, which may answer before the request does
        let seen = records[id]?.events.count ?? 0
        try await ApelinService.app.agentCompact(sessionID: opened.sessionID)
        if let event = records[id]?.events.dropFirst(seen).last(where: { $0.kind == "compactionFinished" }) {
            return Self.compactionResult(event)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                compactions[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.endCompaction(id, with: .failure(CancellationError()))
                try? await ApelinService.app.agentAbort(sessionID: opened.sessionID)
            }
        }
    }

    private func endCompaction(_ id: UUID, with result: Result<AgentCompactionResult, Error>) {
        compactions.removeValue(forKey: id)?.resume(with: result)
    }

    private static func compactionResult(_ event: TaskEvent) -> AgentCompactionResult {
        (try? event.payload?.decode(AgentCompactionResult.self)) ?? AgentCompactionResult(outcome: .failed)
    }

    func modelSelection(for id: UUID) -> ComposerModelSelection? {
        records[id]?.modelSelection
    }

    func setModelSelection(_ selection: ComposerModelSelection?, for id: UUID) {
        guard records[id] != nil else { return }
        records[id]?.modelSelection = selection
        changed(id)
    }

    /// The plan a conversation is on, or nil while it has none: what the
    /// plan bar draws.
    func plan(for id: UUID) -> AgentPlan? {
        plans[id]
    }

    /// What the user asked of the plan in the bar. The session owns the
    /// plan, so the host is asked to pause, resume, end or clear it, and
    /// what it answers is what stands here. A call that fails leaves the bar
    /// as it is, which is all that can honestly be shown.
    func applyPlan(_ action: AgentPlanAction, to id: UUID) async {
        guard let sessionID = records[id]?.sessionID else { return }
        guard let answer = try? await ApelinService.app.agentPlan(sessionID: sessionID, action: action) else {
            return
        }
        guard records[id]?.sessionID == sessionID else { return }
        plans[id] = answer.plan
        changed(id)
        if action == .pause || action == .cancel {
            try? await stop(id)
            await refreshPlan(for: id)
        }
    }

    /// Asks the session for the plan of a conversation opened again: the
    /// session has carried it across a restart, and its events here may not
    /// reach back to where it was written.
    func refreshPlan(for id: UUID) async {
        guard let sessionID = records[id]?.sessionID else {
            plans[id] = nil
            return
        }
        guard let answer = try? await ApelinService.app.agentPlan(sessionID: sessionID) else { return }
        guard records[id]?.sessionID == sessionID else { return }
        plans[id] = answer.plan
        changed(id, urgent: false)
    }

    private func open(_ id: UUID) async throws -> AgentOpenResponse {
        if let pending = opening[id] {
            return try await pending.value
        }
        loadEventsSyncIfNeeded(id)
        guard let record = records[id] else { throw CancellationError() }
        if let sessionID = record.sessionID, let task = record.task, readers[id] != nil {
            return AgentOpenResponse(sessionID: sessionID, task: task)
        }
        let selected = records[id]?.modelSelection ?? ComposerModelSelection.current
        if records[id]?.modelSelection == nil, selected != nil {
            records[id]?.modelSelection = selected
            changed(id)
        }
        let mode = AgentPermissions.mode
        let request = AgentOpenRequest(
            projectName: record.summary.projectName,
            temporaryID: record.summary.projectName == nil ? id.uuidString : nil,
            sessionID: record.sessionID,
            provider: selected?.provider,
            model: selected?.model,
            profileID: selected?.profileID,
            approvalMode: mode,
            asksBeforeScreen: AgentPermissions.asksBeforeScreen,
            reasoningEffort: selected?.effort,
            serviceTier: selected?.tier,
        )
        if request.temporaryID != nil {
            try DataFolder.app.makeLevels(to: DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString))
        }
        let pending = Task { try await ApelinService.app.agentOpen(request) }
        opening[id] = pending
        defer { opening[id] = nil }
        let result = try await pending.value
        guard records[id] != nil else {
            try? await ApelinService.app.agentClose(sessionID: result.sessionID)
            throw CancellationError()
        }
        records[id]?.sessionID = result.sessionID
        records[id]?.reopen(as: result.task)
        changed(id)
        follow(id, task: result.task)
        // the plan the session kept from before, if this conversation has one
        Task { [weak self] in await self?.refreshPlan(for: id) }
        return result
    }

    private func follow(_ id: UUID, task: TaskHandle) {
        loadEventsSyncIfNeeded(id)
        guard readers[id] == nil else { return }
        readers[id] = Task { [weak self] in
            defer {
                self?.readers[id] = nil
                self?.endCompaction(id, with: .failure(ApelinError(
                    .notFound,
                    String(localized: "This chat is no longer running."),
                )))
            }
            while !Task.isCancelled {
                // Only the cursor: a copy of the record held over the wait
                // would make the next batch copy every event to add to them.
                guard let self, records[id]?.task == task, let cursor = records[id]?.cursor else { return }
                do {
                    let batch = try await ApelinService.app.attach(task, afterSeq: cursor)
                    guard !Task.isCancelled, records[id]?.task == task else { return }
                    let fresh = records[id]?.take(batch.events) ?? []
                    let retryable = fresh.contains(where: Self.isRetryableFailure)
                    if retryable {
                        Task { [weak self] in await self?.answerRetryableFailure(in: id) }
                    }
                    settleRetryableFailure(in: id, against: retryable)
                    settleSending(in: id, against: fresh)
                    let builds = CompletedBuilds.count(in: fresh)
                    if builds > 0 {
                        onBuildsCompleted?(builds)
                    }
                    // the launch journal's trail of screen actions and
                    // failed tools, from events read here and nowhere else
                    ScreenActionJournal.note(fresh)
                    for event in fresh where event.kind == AgentConversations.openedEventKind {
                        if let parent = records[id] {
                            adopt(ChatAdoption.record(
                                opened: event.payload,
                                parent: parent,
                                records: Array(records.values),
                            ))
                        }
                    }
                    let dropped = fresh.filter { $0.kind == "queueDropped" }
                        .flatMap { (try? $0.payload?["ids"]?.decode([UUID].self)) ?? [] }
                    if !dropped.isEmpty {
                        restoreDropped(Set(dropped), in: id)
                    }
                    if let title = batch.events.last(where: { $0.kind == "title" })?.payload?["text"]?.stringValue {
                        records[id]?.summary.suggestTitle(title)
                    }
                    // never the replay, which `take` reads past
                    records[id]?.summary.noteReplies(in: fresh, isViewed: id == viewedChat)
                    if let proposed = batch.events
                        .last(where: { $0.kind == "projectNameSuggested" })?.payload?["name"]?.stringValue,
                       let project = records[id]?.summary.projectName,
                       let name = ProjectDisplayName.candidate(proposed)
                    {
                        Task {
                            if let response = try? await ApelinService.app.projectRename(
                                .init(projectID: project, displayName: name, onlyIfAutomatic: true),
                            ), response.changed {
                                NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                            }
                        }
                    }
                    if let finished = fresh.last(where: { $0.kind == "compactionFinished" }) {
                        endCompaction(id, with: .success(Self.compactionResult(finished)))
                    }
                    if fresh.contains(where: ChatPlan.isPlanEvent) {
                        // the last `plan` event with a payload stands, and a
                        // later one without (`planCleared`) takes the bar away
                        plans[id] = ChatPlan.latest(in: records[id]?.events ?? [])
                    }
                    let wasWorking = records[id]?.summary.isWorking
                    let current = transcript(id)
                    let isWorking = current.isWorking || current.isCompacting
                    // A turn that finished (not aborted) while the reader is
                    // not looking at it leaves a green dot until viewed.
                    let finishedTurn = fresh.contains {
                        $0.kind == "finished" && $0.payload?["reason"]?.stringValue != "aborted"
                    }
                    if isWorking {
                        records[id]?.summary.isCompleted = false
                    } else if wasWorking == true, finishedTurn, id != viewedChat {
                        records[id]?.summary.isCompleted = true
                    }
                    // The row's state, never its place in the sidebar: only
                    // the reader's New Chat and messages move that
                    // (`lastInteraction`), however much the agent writes.
                    records[id]?.summary.isWorking = isWorking
                    // A failure that answered while its run still went sends
                    // the next model once that run ends: a session takes a
                    // model between runs, not inside one. Not only the batch
                    // that ends the run: the answer may have been read while
                    // the failed message was still listed as sending, and then
                    // the end of the turn is read in the batch after it.
                    if !isWorking,
                       records[id]?.retryState?.awaitingTurn == true,
                       (records[id]?.sending ?? []).isEmpty
                    {
                        Task { [weak self] in await self?.sendNextModel(in: id, readerAsked: false) }
                    }
                    // A wait that ran out with nothing, as an idle session's
                    // does every 20 s, has nothing to write or show. A turn's
                    // start and end are written at once, what streams between
                    // them at most every `saveInterval`.
                    let turnMoved = isWorking != wasWorking
                    if !batch.events.isEmpty || turnMoved {
                        changed(id, urgent: turnMoved || batch.finished)
                    }
                    if batch.finished {
                        if let end = records[id]?.missedEnd(of: batch, isWorking: isWorking) {
                            await takeMissedEnd(at: end, of: task, from: batch, in: id)
                        }
                        return
                    }
                } catch let error as ApelinError where error.code == .notFound {
                    // The service that owned this task is not there: killed,
                    // or back with the task gone. A turn that was in flight
                    // is not lost — the conversation is opened again as soon
                    // as the service answers, and the agent side sends the
                    // same message again instead of losing it. A turn the
                    // reader stopped itself stays stopped.
                    let owed = records[id]?.summary.isWorking == true
                        || !(records[id]?.sending ?? []).isEmpty
                    records[id]?.summary.isWorking = false
                    changed(id)
                    if owed { resumeCutTurnWhenServiceReturns(id) }
                    return
                } catch is CancellationError { return }
                catch {
                    // A lost connection does not discard the cursor or stop a remote turn.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// Takes a cut turn up again once the background service answers. The
    /// daemon is started on demand, so after a kill it is away for a moment
    /// and launchd starts it again when something asks; until it answers
    /// nothing is asked of it, and then the conversation is opened — which is
    /// what makes the agent side send the same message again in place of the
    /// one that was cut short. A chat the reader stopped itself is left
    /// stopped, and each chat is taken up again at most once.
    private func resumeCutTurnWhenServiceReturns(_ id: UUID) {
        guard cutTurnResumes < Self.maximumCutTurnResumes,
              !stoppedChats.contains(id),
              !resumingCutTurn.contains(id)
        else { return }
        resumingCutTurn.insert(id)
        Task { [weak self] in
            defer { self?.resumingCutTurn.remove(id) }
            // about two minutes of asking: a relaunch follows a kill, but not
            // at once, and nothing is opened while the service is away
            for _ in 0..<60 {
                guard let self, self.records[id] != nil else { return }
                if (try? await ApelinService.app.agentList()) != nil,
                   (try? await self.open(id)) != nil {
                    self.cutTurnResumes += 1
                    log.info("service answered: took a cut turn up again")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            log.info("service did not answer: a cut turn waits for the next open")
        }
    }

    /// The end of `task` the conversation read past (`ChatRecord.missedEnd`),
    /// read again from just before it unless `batch` carries it, and taken.
    private func takeMissedEnd(at end: EventSeq, of task: TaskHandle, from batch: TaskEventBatch, in id: UUID) async {
        var event = batch.events.last { $0.seq == end }
        if event == nil {
            event = try? await ApelinService.app.attach(task, afterSeq: EventSeq(end.rawValue - 1), waitMilliseconds: 0)
                .events.first
        }
        guard records[id]?.task == task else { return }
        records[id]?.takeMissedEnd(event, at: end)
        changed(id)
    }

    /// Sent messages whose echo arrived leave `sending`, in the same
    /// update that adds the event, so the row never blinks out or doubles.
    /// Each echoed attachment is cached as the very one the local row
    /// showed, so its preview does not fade in again.
    private func settleSending(in id: UUID, against events: [TaskEvent]) {
        guard let draftID = records[id]?.draft.id,
              let echoed = records[id]?.takeEchoed(by: events) else { return }
        for (draft, event) in echoed {
            let saved = (try? event.payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
            guard saved.count == draft.attachments.count else { continue }
            for (item, local) in zip(saved, draft.attachments) {
                if let path = attachmentPath(item, in: id) {
                    attachmentCache[path] = local
                }
            }
        }
        if records[id]?.draft.id != draftID {
            onDraftRestored?(id)
        }
    }

    /// What a stopped run never took goes back to the composer, ahead of
    /// what was typed since (`DroppedMessages`).
    private func restoreDropped(_ messages: Set<UUID>, in id: UUID) {
        guard let events = records[id]?.events, let draft = records[id]?.draft,
              let returned = DroppedMessages.returning(messages, from: events, to: draft, attachment: {
                  attachment($0, in: id)
              })
        else { return }
        records[id]?.draft = returned.draft
        onDraftRestored?(id)
        onUnsentReturned?(id, returned)
    }

    // MARK: - A failure the retry answers

    /// A model answered with a spent allowance, or a key the provider
    /// refused. The reader's message goes again with the next candidate of
    /// `ModelCandidates.fallbackList` — the same model on another
    /// configuration of the provider first, which is another key — and the
    /// model bar keeps a Retry while that list has one left.
    private func answerRetryableFailure(in id: UUID) async {
        // One answer at a time: the models are looked up over the wire, and
        // a second error read meanwhile would answer the same one twice.
        loadEventsSyncIfNeeded(id)
        guard records[id] != nil, !answeringRetryableFailure.contains(id) else { return }
        answeringRetryableFailure.insert(id)
        defer { answeringRetryableFailure.remove(id) }
        var state: ModelRetryState
        if let known = records[id]?.retryState {
            // later errors of the same run keep the tries and the list
            state = known
        } else {
            let failedKey = (records[id]?.modelSelection ?? ComposerModelSelection.current)?.retryKey
            state = ModelRetryState(
                remaining: await fallbackCandidates(after: id),
                triedKeys: failedKey.map { Set([$0]) } ?? Set(),
                text: "",
            )
        }
        // What the failure was, from its own wording: it decides whether the
        // automatic retry runs and how long the candidate that failed waits.
        let kind = failureKind(in: id)
        if let kind {
            state.kind = kind
            if let wait = ModelRetryPolicy.cooldown(for: kind),
               let failed = (records[id]?.modelSelection ?? ComposerModelSelection.current)?.retryKey
            {
                var cooldowns = state.cooldowns ?? [:]
                cooldowns[failed] = Date().addingTimeInterval(wait)
                state.cooldowns = cooldowns
                // Never try this key again in this retry chain.
                state.triedKeys.insert(failed)
            }
        }
        // Drop any candidate that has already failed.
        state.remaining = state.remaining.filter { !state.triedKeys.contains($0.retryKey) }
        // The message the error answered, which a newer one the reader sent
        // meanwhile takes over: the retry sends what failed.
        let draft = retryDraft(in: id, fallbackText: state.text)
        state.text = draft.text
        // With nothing to send again, or no model left, the conversation
        // keeps the error alone: the reader is the one who acts.
        guard !state.remaining.isEmpty, Self.hasContent(draft) else {
            if records[id]?.retryState != nil {
                records[id]?.retryState = nil
                changed(id)
            }
            return
        }
        records[id]?.retryState = state
        changed(id)
        // A failure no candidate answers the same request for — one that never
        // arrived, which may still have been served — leaves the candidates to
        // the reader's own Retry: the model bar keeps the button, and nothing
        // is sent again on its own.
        guard kind.map(ModelRetryPolicy.automatic) ?? true else { return }
        await sendNextModel(in: id, readerAsked: false)
    }

    /// The reader's Retry in the model bar: the next model, whether or not
    /// the automatic tries are spent.
    func retryFailedMessage(_ id: UUID) async {
        loadEventsSyncIfNeeded(id)
        await sendNextModel(in: id, readerAsked: true)
    }

    /// Whether `id` has a candidate left to answer a failure with: what the
    /// model bar's Retry is shown for.
    func canRetryFailedMessage(_ id: UUID) -> Bool {
        records[id]?.retryState.map { !$0.remaining.isEmpty } ?? false
    }

    private func sendNextModel(in id: UUID, readerAsked: Bool) async {
        loadEventsSyncIfNeeded(id)
        guard var state = records[id]?.retryState,
              let next = state.nextCandidate(readerAsked: readerAsked) else { return }
        // One retry at a time: the same message sent twice would run twice,
        // and a send under way is a prompt the host already has.
        guard (records[id]?.sending ?? []).isEmpty else { return }
        let draft = retryDraft(in: id, fallbackText: state.text)
        let step = ModelRetryPolicy.step(
            attempts: state.attempts,
            candidatesLeft: state.remaining.count,
            hasMessage: Self.hasContent(draft),
            isWorking: records[id]?.summary.isWorking ?? false,
            readerAsked: readerAsked,
            automatic: state.kind.map(ModelRetryPolicy.automatic) ?? true,
        )
        // The model that answered with nothing left spent carries the wait
        // the run it belongs to imposes: `follow` sends the next one when
        // that run ends.
        if state.awaitingTurn != (step == .wait) {
            state.awaitingTurn = step == .wait
            records[id]?.retryState = state
            changed(id)
        }
        guard step == .send else { return }
        if let index = state.remaining.firstIndex(of: next) {
            state.remaining.remove(at: index)
        }
        state.attempts += 1
        state.awaitingTurn = nil
        let previous = records[id]?.modelSelection
        records[id]?.retryState = state
        // this conversation runs on the model that answers from here on
        records[id]?.modelSelection = next
        records[id]?.submit(draft)
        changed(id)
        do {
            try await send(draft, to: id)
        } catch {
            // A send that never reached the host spent neither the model
            // nor the try, and the conversation keeps the model it had.
            takeBack(draft, from: id)
            if var back = records[id]?.retryState {
                back.remaining.insert(next, at: 0)
                back.attempts = max(back.attempts - 1, 0)
                records[id]?.retryState = back
            }
            if records[id]?.modelSelection == next {
                records[id]?.modelSelection = previous
            }
            changed(id)
        }
    }

    /// The message a spent allowance sends again: the reader's last one the
    /// allowance answered, with the files it carried, read from the
    /// conversation's own events. One sent after the error is not it — the
    /// run it joined never got the error — and a queued one still in the
    /// host's queue would go twice. `fallbackText` is what a state written
    /// before that holds.
    private func retryDraft(in id: UUID, fallbackText: String) -> ComposerDraft {
        guard let events = records[id]?.events else { return ComposerDraft(text: fallbackText) }
        // The error's own place: the message it answered is the one before.
        let anchor = events.last(where: Self.isRetryableFailure)?.seq
        let answered = anchor.map { anchor in
            events.last { $0.seq < anchor && ChatTranscript.userMessageID(of: $0) != nil }
        } ?? events.last { ChatTranscript.userMessageID(of: $0) != nil }
        guard let event = answered
        else { return ComposerDraft(text: fallbackText) }
        let text = event.payload?["text"]?.stringValue ?? ""
        let saved = ChatTranscript.attachments(in: event.payload?["attachments"])
        let files = saved.compactMap { attachment($0, in: id) }
        guard !text.isEmpty || !files.isEmpty else { return ComposerDraft(text: fallbackText) }
        return ComposerDraft(text: text, attachments: files)
    }

    /// Whether `draft` carries a message: text, files, or both.
    private static func hasContent(_ draft: ComposerDraft) -> Bool {
        !draft.text.isEmpty || !draft.attachments.isEmpty
    }

    /// The models to fall back to after the one `id` runs on, in
    /// `ModelCandidates`' order, as the selections a prompt sends with.
    /// Another key for the same model always; another model only where the
    /// reader turned that on (`ModelFallback.triesOtherModels`).
    private func fallbackCandidates(after id: UUID) async -> [ComposerModelSelection] {
        guard let listed = try? await ApelinService.app.agentAccountList().accounts else { return [] }
        let current = records[id]?.modelSelection ?? ComposerModelSelection.current
        return ModelCandidates.fallbackList(
            current: current,
            accounts: listed,
            otherModels: ModelFallback.triesOtherModels,
        ).map(\.selection)
    }

    /// The conversation answered again after a failure the retry answers — a
    /// message finished past its last error, and the turn ended — so the
    /// retry has done what it could. A turn that ends on an error of its own
    /// never clears it: its message came before that error, not after.
    private func settleRetryableFailure(in id: UUID, against retryable: Bool) {
        guard !retryable, records[id]?.retryState != nil,
              let events = records[id]?.events,
              let anchor = events.last(where: Self.isRetryableFailure)?.seq,
              events.contains(where: {
                  $0.kind == "message" && $0.seq > anchor
              }),
              events.contains(where: {
                  $0.kind == "finished" && $0.seq > anchor
                      && $0.payload?["reason"]?.stringValue != "aborted"
              })
        else { return }
        records[id]?.retryState = nil
        changed(id)
    }

    /// The failures `ModelRetrySignal` names, on an error event of the run:
    /// the host words a spent allowance as a sentence of its own and passes a
    /// provider's refusal through (`AgentSession`), and an older host passes
    /// both through.
    private static func isRetryableFailure(_ event: TaskEvent) -> Bool {
        event.kind == "error" && ModelRetrySignal.matches(event.payload?["message"]?.stringValue ?? "")
    }

    /// What the last such failure was, from its own wording: the kind a
    /// cooldown and the automatic-retry gate are decided by. nil when nothing
    /// in the conversation names one — a state read from disk that is being
    /// answered after a relaunch, whose error event the replay has not
    /// reached yet — and then the retry behaves as it did before kinds were
    /// kept.
    private func failureKind(in id: UUID) -> ModelFailureKind? {
        records[id]?.events
            .last(where: Self.isRetryableFailure)?
            .payload?["message"]?
            .stringValue
            .flatMap(ModelRetrySignal.kind(of:))
    }

    /// `urgent`: written at once rather than after the interval; see `persist`.
    private func changed(_ id: UUID, urgent: Bool = true) {
        loadEventsSyncIfNeeded(id)
        persist(id, urgent: urgent); onChange?()
    }

    /// Writes `id`, atomically and off the main thread (`ChatStore`). An
    /// `urgent` save goes now, or as soon as the write under way ends; any
    /// other waits until `saveInterval` after the last write ended.
    private func persist(_ id: UUID, urgent: Bool = false) {
        guard records[id] != nil else {
            unsaved.remove(id)
            savesDeferred.removeValue(forKey: id)?.cancel()
            return
        }
        if saving.contains(id) {
            savesPending.insert(id)
            if urgent {
                savesUrgent.insert(id)
            }
            return
        }
        let due = savedAt[id].map { $0 + Self.saveInterval } ?? .now
        if urgent || due <= .now {
            savesDeferred.removeValue(forKey: id)?.cancel()
            write(id)
        } else if savesDeferred[id] == nil {
            savesDeferred[id] = Task { [weak self] in
                try? await Task.sleep(until: due)
                guard !Task.isCancelled, let self else { return }
                savesDeferred[id] = nil
                write(id)
            }
        }
    }

    /// Writes every conversation whose save is waiting for its interval,
    /// before the app is suspended; `drained` is called once none is being
    /// written.
    func saveNow(drained: @escaping () -> Void) {
        for id in Set(savesDeferred.keys).union(savesPending) {
            persist(id, urgent: true)
        }
        savesDrained.append(drained)
        drainSaves()
    }

    private func drainSaves() {
        guard saving.isEmpty else { return }
        let drained = savesDrained
        savesDrained = []
        drained.forEach { $0() }
    }

    private func write(_ id: UUID) {
        loadEventsSyncIfNeeded(id)
        guard let record = records[id] else {
            unsaved.remove(id)
            return
        }
        saving.insert(id)
        revision += 1
        let revision = revision
        Task { [store, weak self] in
            do {
                try await store.save(record, revision: revision)
                self?.saved(id)
            } catch {
                self?.unsaved.insert(id)
                self?.onSaveFailure?(error)
            }
            self?.saveEnded(id)
        }
    }

    /// Writes what changed while `id` was being written.
    private func saveEnded(_ id: UUID) {
        saving.remove(id)
        savedAt[id] = .now
        if savesPending.remove(id) != nil {
            persist(id, urgent: savesUrgent.remove(id) != nil)
        }
        drainSaves()
    }

    /// Writes again every conversation a failed save left in memory only.
    func retryUnsaved() {
        for id in unsaved {
            persist(id, urgent: true)
        }
    }

    private func saved(_ id: UUID) {
        guard unsaved.remove(id) != nil else { return }
        onSaveRecovered?()
        retryUnsaved()
    }

    private func imageMIME(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

private extension DataFolder {
    /// Removes a temporary conversation's one real directory directly inside
    /// `Temporary/`, as `removeProject` does a project's: links inside it are
    /// removed, never followed.
    func removeTemporaryFolder(of id: UUID) throws {
        let folder = root.appendingPathComponent("Temporary/" + id.uuidString)
        var metadata = stat()
        if lstat(folder.path, &metadata) != 0 {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              let rootPath = CanonicalPath.resolve(root.path),
              CanonicalPath.resolve(folder.path) == rootPath + "/Temporary/" + id.uuidString
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: folder)
    }
}
