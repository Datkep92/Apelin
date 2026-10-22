import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Owns chat history, drafts and live sessions independently of the selected page.
@MainActor
final class ChatRuntime {
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
    private(set) var isLoaded = false
    private(set) var records: [UUID: ChatRecord] = [:]
    private let store = ChatStore(folder: .app)
    private var revision = 0
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var opening: [UUID: Task<AgentOpenResponse, Error>] = [:]
    private var attachmentCache: [String: ComposerAttachment] = [:]
    /// Conversations whose latest state is in memory only.
    private var unsaved: Set<UUID> = []

    var summaries: [ChatSummary] {
        records.values.map(\.summary)
    }

    /// Reads every saved conversation. An untouched one left by an earlier
    /// launch is dropped, unless it is `selected`, the one to show again.
    func load(keeping selected: UUID?) async {
        do {
            for var record in try await store.load() {
                let unsent = record.sending != nil
                record.reclaimUnsent()
                records[record.summary.id] = record
                if unsent {
                    persist(record.summary.id)
                }
            }
            for record in records.values where isUntouched(record) && record.summary.id != selected {
                try? await removeRecord(record.summary.id)
                if record.summary.projectName == nil {
                    // the folder the menu's Open in iGhostVT or Fila made, if
                    // it was left empty; rmdir takes nothing else
                    rmdir(DataFolder.app.root.appendingPathComponent("Temporary/" + record.summary.id.uuidString).path)
                }
            }
            isLoaded = true
            onChange?()
            // A host that does not answer yet is not an error, and runs
            // nothing this app could follow: every saved row stops working.
            let live = await (try? ApelinService.app.agentList().sessions) ?? []
            for record in records.values {
                if let session = live.first(where: { $0.sessionID == record.sessionID }) {
                    records[record.summary.id]?.task = session.task
                    follow(record.summary.id, task: session.task)
                } else if record.summary.isWorking {
                    records[record.summary.id]?.summary.isWorking = false
                    changed(record.summary.id)
                }
            }
            // What agents opened while the app was not following their
            // openers; the list is oldest first, so an opener comes first.
            for session in live {
                adopt(ChatAdoption.record(session: session, records: Array(records.values)))
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

    /// A conversation to start in `project`: its untouched one, `current`
    /// first, brought to now, or else a new one.
    func newChat(project: String?, preferring current: UUID?) -> ChatSummary {
        let untouched = records.values.filter { $0.summary.projectName == project && isUntouched($0) }
        let reused = untouched.first { $0.summary.id == current }
            ?? untouched.max { $0.summary.updated < $1.summary.updated }
        let summary = reused?.summary
            ?? ChatSummary(title: String(localized: "New Chat"), updated: Date(), projectName: project)
        if reused == nil {
            records[summary.id] = ChatRecord(summary: summary)
        }
        records[summary.id]?.summary.updated = Date()
        changed(summary.id)
        return records[summary.id]?.summary ?? summary
    }

    /// Nothing sent, typed or attached, no session opening, not pinned and
    /// not named: a row that holds nothing but its place.
    private func isUntouched(_ record: ChatRecord) -> Bool {
        record.events.isEmpty && record.sessionID == nil && record.task == nil && opening[record.summary.id] == nil
            && record.sending == nil && record.draft.text.isEmpty && record.draft.attachments.isEmpty
            && !record.summary.isPinned && record.summary.isNamedByReader != true
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

    func delete(_ id: UUID) async throws {
        try await closeSession(id)
        let isTemporary = records[id].map { $0.summary.projectName == nil } ?? false
        try await removeRecord(id)
        onChange?()
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
            try await closeSession(id)
        }
        let folder = DataFolder.app
        try await Task.detached { try folder.removeProject(named: name) }.value
        defer { onChange?() }
        for id in ids {
            try await removeRecord(id)
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
        // Keep the in-memory row on disk failure, so Delete can be retried.
        try await store.remove(id)
        readers.removeValue(forKey: id)?.cancel()
        records.removeValue(forKey: id)
    }

    func transcript(_ id: UUID) -> ChatTranscript {
        let record = records[id]
        let conversationTitle = { [records] (sessionID: String) in
            records.values.first { $0.sessionID == sessionID }?.summary.title
        }
        return ChatTranscript(
            events: record?.events ?? [],
            sending: record?.sending ?? [],
            conversationTitle: conversationTitle,
        ) { [self] item in
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
        guard var record = records[id] else { return Task {} }
        record.sending = (record.sending ?? []) + [draft]
        if record.draft.id == draft.id {
            record.draft = ComposerDraft()
        }
        records[id] = record
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
        let selection = ComposerModelSelection.current
        _ = try await ApelinService.app.send(
            AgentPromptRequest(
                sessionID: opened.sessionID,
                text: draft.text,
                messageID: draft.id,
                attachments: inputs,
                provider: selection?.provider,
                model: selection?.model,
                reasoningEffort: selection?.effort,
                approvalMode: AgentPermissions.mode,
            ),
            descriptors: descriptors,
        )
        if records[id]?.summary.title == String(localized: "New Chat") {
            records[id]?.summary.suggestTitle(String(
                (draft.text.isEmpty ? draft.attachments.first?.name ?? String(localized: "New Chat") : draft.text)
                    .prefix(80),
            ))
        }
        records[id]?.summary.updated = Date()
        changed(id)
    }

    func approve(_ messageID: UUID, in id: UUID, decision: ApprovalDecision) async throws {
        guard let sessionID = records[id]?.sessionID,
              let approvalID = transcript(id).approvalIDs[messageID]
        else { return }
        try await ApelinService.app.agentApprove(sessionID: sessionID, approvalID: approvalID, decision: decision)
    }

    func stop(_ id: UUID) async throws {
        guard let sessionID = records[id]?.sessionID else { return }
        try await ApelinService.app.agentAbort(sessionID: sessionID)
    }

    private func open(_ id: UUID) async throws -> AgentOpenResponse {
        if let pending = opening[id] {
            return try await pending.value
        }
        guard let record = records[id] else { throw CancellationError() }
        if let sessionID = record.sessionID, let task = record.task, readers[id] != nil {
            return AgentOpenResponse(sessionID: sessionID, task: task)
        }
        let selected = ComposerModelSelection.current
        let mode = AgentPermissions.mode
        let request = AgentOpenRequest(
            projectName: record.summary.projectName,
            temporaryID: record.summary.projectName == nil ? id.uuidString : nil,
            sessionID: record.sessionID,
            provider: selected?.provider,
            model: selected?.model,
            approvalMode: mode,
            reasoningEffort: selected?.effort,
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
        if records[id]?.task != result.task {
            records[id]?.events = []
        }
        records[id]?.sessionID = result.sessionID
        records[id]?.task = result.task
        changed(id)
        follow(id, task: result.task)
        return result
    }

    private func follow(_ id: UUID, task: TaskHandle) {
        guard readers[id] == nil else { return }
        readers[id] = Task { [weak self] in
            defer { self?.readers[id] = nil }
            while !Task.isCancelled {
                guard let self, let record = records[id], record.task == task else { return }
                do {
                    let batch = try await ApelinService.app.attach(task, afterSeq: record.events.last?.seq ?? .start)
                    guard !Task.isCancelled, records[id]?.task == task else { return }
                    let after = records[id]?.events.last?.seq ?? .start
                    let fresh = batch.events.filter { $0.seq > after }
                    records[id]?.events.append(contentsOf: fresh)
                    settleSending(in: id, against: fresh)
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
                    let isWorking = transcript(id).isWorking
                    records[id]?.summary.isWorking = isWorking
                    if let last = batch.events.last {
                        records[id]?.summary.updated = last.time
                    }
                    changed(id)
                    if batch.finished {
                        return
                    }
                } catch let error as ApelinError where error.code == .notFound {
                    records[id]?.summary.isWorking = false
                    changed(id)
                    return
                } catch is CancellationError { return }
                catch {
                    // A lost connection does not discard the cursor or stop a remote turn.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
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

    /// What a stopped run never took goes back to the composer, when
    /// nothing else is typed there.
    private func restoreDropped(_ messages: Set<UUID>, in id: UUID) {
        let texts = (records[id]?.events ?? []).filter { $0.kind == "queued" }.compactMap { event -> String? in
            guard let message = event.payload?["id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  messages.contains(message)
            else { return nil }
            return event.payload?["text"]?.stringValue
        }
        guard !texts.isEmpty, let draft = records[id]?.draft,
              draft.text.isEmpty, draft.attachments.isEmpty
        else { return }
        records[id]?.draft = ComposerDraft(text: texts.joined(separator: "\n\n"))
        onDraftRestored?(id)
    }

    private func changed(_ id: UUID) {
        persist(id); onChange?()
    }

    private func persist(_ id: UUID) {
        guard let record = records[id] else {
            unsaved.remove(id)
            return
        }
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
        }
    }

    /// Writes again every conversation a failed save left in memory only.
    func retryUnsaved() {
        for id in unsaved {
            persist(id)
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
