import ApelinAgent
import ApelinProtocol
import Foundation

public extension ChannelHostBackend {
    // MARK: conversations

    func conversationCreate(
        _ request: ConversationCreateToolRequest,
    ) async throws -> ConversationCreateToolResponse {
        let choice = await modelChoice.current
        // The host opens it in this session's project under this session's
        // mode, whatever the request names; the mode here is a placeholder.
        let opened = try await conversation("conversation_create") {
            try await service.agentOpen(AgentOpenRequest(
                projectID: project.id,
                projectName: project.name.rawValue,
                provider: choice.provider,
                model: choice.model,
                approvalMode: .confirm,
                reasoningEffort: choice.reasoningEffort,
                prompt: request.prompt,
                title: request.title,
            ))
        }
        return ConversationCreateToolResponse(sessionID: opened.sessionID, taskID: opened.task.taskID.rawValue)
    }

    func conversationSend(
        _ request: ConversationSendToolRequest,
    ) async throws -> ConversationActionToolResponse {
        try await conversation("conversation_send") {
            _ = try await service.send(AgentPromptRequest(sessionID: request.sessionID, text: request.text))
        }
        return ConversationActionToolResponse(sessionID: request.sessionID, done: "sent")
    }

    func conversationList(context _: HostCallContext) async throws -> ConversationListToolResponse {
        let sessions = try await conversation("conversation_list") { try await service.agentList().sessions }
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
        let sessions = try await conversation("conversation_read") { try await service.agentList().sessions }
        guard let summary = sessions.first(where: { $0.sessionID == request.sessionID }) else {
            throw ConversationToolFailure(message: "conversation_read failed: this project has no conversation \(request.sessionID). conversation_list names them.")
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
            default:
                break
            }
            throw ConversationToolFailure(message: text)
        }
    }
}
