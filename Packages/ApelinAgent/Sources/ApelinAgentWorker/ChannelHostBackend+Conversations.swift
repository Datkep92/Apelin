import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

public extension ChannelHostBackend {
    // MARK: conversations

    func conversationCreate(
        _ request: ConversationCreateToolRequest,
    ) async throws -> ConversationCreateToolResponse {
        let choice = await modelChoice.current
        let target = request.target ?? project
        // The host opens it in that project, resolved again, under this
        // session's mode; the mode here is a placeholder.
        let opened = try await conversation("conversation_create") {
            try await service.agentOpen(AgentOpenRequest(
                projectID: target.id,
                projectName: target.name.rawValue,
                provider: choice.provider,
                model: choice.model,
                approvalMode: .confirm,
                reasoningEffort: choice.reasoningEffort,
                prompt: request.prompt,
                title: request.title,
            ))
        }
        return ConversationCreateToolResponse(
            sessionID: opened.sessionID,
            taskID: opened.task.taskID.rawValue,
            project: request.target,
        )
    }

    func conversationSend(
        _ request: ConversationSendToolRequest,
    ) async throws -> ConversationActionToolResponse {
        try await conversation("conversation_send") {
            _ = try await service.send(AgentPromptRequest(sessionID: request.sessionID, text: request.text))
        }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "sent")
    }

    func conversationList(_ request: ConversationListToolRequest) async throws -> ConversationListToolResponse {
        let sessions = try await conversation("conversation_list") {
            try await service.agentList(projectID: request.target?.id).sessions
        }
        return ConversationListToolResponse(conversations: sessions.map { summary in
            ConversationSummary(
                sessionID: summary.sessionID,
                title: summary.title,
                state: summary.state.isTerminal
                    ? "ended"
                    : summary.state == .waitingForApproval ? "waitingForApproval" : "open",
                openedBy: summary.parentSessionID,
                updatedAt: summary.updatedAt,
                isThisConversation: summary.sessionID == sessionID,
            )
        })
    }

    func conversationRead(_ request: ConversationReadToolRequest) async throws -> ConversationReadToolResponse {
        let sessions = try await conversation("conversation_read") {
            try await service.agentList(projectID: request.target?.id).sessions
        }
        guard let summary = sessions.first(where: { $0.sessionID == request.sessionID }) else {
            let scope = request.target.map { "the project \($0.name.rawValue)" } ?? "this project"
            throw ConversationToolFailure(message: "conversation_read failed: \(scope) has no conversation \(request.sessionID). conversation_list names them; pass project for another project's.")
        }
        var reader = ConversationReader(afterSeq: request.afterSeq ?? 0, byteLimit: Self.maximumConversationBytes)
        // The whole log, a batch at a time: the state and the approvals still
        // waiting depend on what came before `afterSeq` too.
        var cursor = EventSeq.start
        while true {
            let batch = try await conversation("conversation_read") {
                try await service.agentAttach(AgentAttachRequest(
                    taskID: summary.task.taskID,
                    afterSeq: cursor,
                    waitMilliseconds: 0,
                ))
            }
            reader.take(batch)
            guard batch.lastSeq > cursor, !batch.events.isEmpty, !batch.finished else { break }
            cursor = batch.lastSeq
        }
        let deadline = Date().addingTimeInterval(
            Double(min(ConversationReadToolRequest.maximumWaitSeconds, max(0, request.waitSeconds))),
        )
        var timedOut = false
        while !reader.isSettled {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                timedOut = request.waitSeconds > 0
                break
            }
            let wait = min(Self.conversationPollMilliseconds, max(1, Int(remaining * 1000)))
            let batch = try await conversation("conversation_read") {
                try await service.agentAttach(AgentAttachRequest(
                    taskID: summary.task.taskID,
                    afterSeq: reader.lastSeq,
                    waitMilliseconds: wait,
                ))
            }
            reader.take(batch)
        }
        return reader.response(sessionID: summary.sessionID, title: summary.title, timedOut: timedOut)
    }

    func conversationStop(
        _ request: ConversationStopToolRequest,
    ) async throws -> ConversationActionToolResponse {
        try await conversation("conversation_stop") { try await service.agentAbort(sessionID: request.sessionID) }
        guard request.close else {
            return ConversationActionToolResponse(sessionID: request.sessionID, done: "stopped")
        }
        try await conversation("conversation_stop") { try await service.agentClose(sessionID: request.sessionID) }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "closed")
    }

    /// One conversation request; a refusal comes back in words the model
    /// can act on.
    private func conversation<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ApelinError {
            var text = "\(operation) failed: \(error.message.isEmpty ? error.code.rawValue : error.message)"
            if !text.hasSuffix(".") {
                text += "."
            }
            switch (operation, error.code) {
            case ("conversation_create", .conflict):
                text += " Wait for one to finish, or end one you opened with conversation_stop and close: true."
            case ("conversation_send", .notFound):
                text += " That conversation is not running any more; the user can reopen it from the sidebar."
            case (_, .denied) where error.message.hasPrefix("approval required"):
                text += " If it is in another project, name that project with project; the user is asked each time."
            default:
                break
            }
            throw ConversationToolFailure(message: text)
        }
    }

    /// A project under `Projects/` by its folder name or its projectID, as
    /// the host resolves `agentOpen`'s: a folder that is a link out of
    /// `Projects/` is not taken. The host resolves it again and decides.
    func resolveProject(_ reference: String) async throws -> ApelinAgent.ProjectIdentity {
        let reference = reference.trimmingCharacters(in: .whitespaces)
        guard !reference.isEmpty, !reference.contains("\0") else {
            throw ConversationToolFailure(message: "name the project by its projectID or folder name")
        }
        let root = projectsURL.resolvingSymlinksInPath()
        func identity(_ name: String) -> ApelinAgent.ProjectIdentity? {
            guard let folder = try? ApelinAgent.ProjectName(name) else { return nil }
            let url = root.appendingPathComponent(name, isDirectory: true)
            let manifest = url.appendingPathComponent("apelin-project.json")
            // As the host reads it: a regular file, not a link, bounded.
            guard url.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1 << 20,
                  let data = try? Data(contentsOf: manifest),
                  let json = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data),
                  let id = json["projectID"]?.stringValue, !id.isEmpty
            else { return nil }
            return ApelinAgent.ProjectIdentity(id: id, name: folder)
        }
        if let named = identity(reference) {
            return named
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names.sorted() where !name.hasPrefix(".") {
            if let found = identity(name), found.id == reference {
                return found
            }
        }
        throw ConversationToolFailure(message: "no project is named or has the id \(reference); use the folder name or projectID project_create answered, or ask the user")
    }
}
