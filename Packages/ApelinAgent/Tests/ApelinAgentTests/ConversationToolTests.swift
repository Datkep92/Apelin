@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("conversation tools")
struct ConversationToolTests {
    static let tools: [AgentToolName] = [
        .conversationCreate, .conversationSend, .conversationList, .conversationRead, .conversationStop,
    ]

    // MARK: Catalog

    @Test
    func `the catalog names the conversation tools with their risks, for projects only`() {
        #expect(Self.tools.map(\.rawValue) == [
            "conversation_create", "conversation_send", "conversation_list", "conversation_read", "conversation_stop",
        ])
        for tool in [AgentToolName.conversationCreate, .conversationSend, .conversationStop] {
            #expect(tool.risk == .writeProject, "\(tool.rawValue)")
        }
        for tool in [AgentToolName.conversationList, .conversationRead] {
            #expect(tool.risk == .readOnly, "\(tool.rawValue)")
            #expect(!tool.isSensitiveRead, "\(tool.rawValue)")
        }
        for tool in Self.tools {
            #expect(tool.isProjectOnly, "\(tool.rawValue)")
            #expect(!tool.isGeneralChatOnly, "\(tool.rawValue)")
            #expect(!tool.summary.isEmpty)
        }
    }

    @Test
    func `each tool takes what it needs, and a reason`() {
        func schema(_ tool: AgentToolName) -> (properties: Set<String>, required: [String]) {
            guard case let .object(fields) = ToolReason.adding(to: tool.parameters),
                  case let .object(properties)? = fields["properties"],
                  case let .array(required)? = fields["required"] else { return ([], []) }
            return (Set(properties.keys), required.compactMap {
                if case let .string(name) = $0 {
                    name
                } else {
                    nil
                }
            })
        }
        #expect(schema(.conversationCreate).properties == ["prompt", "title", "reason"])
        #expect(schema(.conversationCreate).required == ["prompt", "reason"])
        #expect(schema(.conversationSend).required == ["session_id", "text", "reason"])
        #expect(schema(.conversationList).properties == ["reason"])
        #expect(schema(.conversationRead).properties == ["session_id", "after_seq", "wait_seconds", "reason"])
        #expect(schema(.conversationStop).properties == ["session_id", "close", "reason"])
    }

    @Test
    func `a project's chat offers them; General Chat does not`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        func offered(_ project: ProjectIdentity) throws -> [String] {
            try ToolRunner(
                sessionID: UUID().uuidString,
                project: project,
                root: ScopedRoot(home.projectURL),
                policy: ApprovalPolicy(mode: .confirm),
                backend: MockBackend(),
                digests: MockDigestLedger(),
                gate: ApprovalGate { _ in },
            ).agentTools(mcp: []).map(\.name)
        }
        let project = try offered(home.project)
        let id = UUID().uuidString
        let general = try offered(ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)))
        for tool in Self.tools {
            #expect(project.contains(tool.rawValue), "\(tool.rawValue)")
            #expect(!general.contains(tool.rawValue), "\(tool.rawValue)")
        }
    }

    // MARK: Approval

    @Test
    func `Confirm lets every conversation tool through without asking`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        let policy = ApprovalPolicy(mode: .confirm)
        for tool in [AgentToolName.conversationCreate, .conversationSend, .conversationStop] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.notRequired), "\(tool.rawValue)")
        }
        for tool in [AgentToolName.conversationList, .conversationRead] {
            #expect(policy.evaluate(InvocationFacts(tool: .local(tool)), root: root) == .allow(.preset(tool.rawValue)), "\(tool.rawValue)")
        }
    }

    // MARK: Running

    @Test
    func `each tool is one backend call with its arguments, and none asks`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        var asked = 0
        asked += try await harness.run(.conversationCreate, ["prompt": "Write the README", "title": "Docs"]).1.count
        asked += try await harness.run(.conversationCreate, ["prompt": "Check the filter", "title": ""]).1.count
        asked += try await harness.run(.conversationSend, ["session_id": "child-session", "text": "Also the changelog"]).1.count
        asked += try await harness.run(.conversationList, [:]).1.count
        asked += try await harness.run(.conversationRead, ["session_id": "child-session", "after_seq": 12, "wait_seconds": 5000]).1.count
        asked += try await harness.run(.conversationRead, ["session_id": "child-session", "wait_seconds": -3]).1.count
        asked += try await harness.run(.conversationStop, ["session_id": "child-session"]).1.count
        asked += try await harness.run(.conversationStop, ["session_id": "child-session", "close": true]).1.count
        #expect(asked == 0)
        #expect(await harness.backend.calls == [
            .conversationCreate(prompt: "Write the README", title: "Docs"),
            .conversationCreate(prompt: "Check the filter", title: nil),
            .conversationSend(sessionID: "child-session", text: "Also the changelog"),
            .conversationList,
            .conversationRead(sessionID: "child-session", afterSeq: 12, waitSeconds: 600),
            .conversationRead(sessionID: "child-session", afterSeq: nil, waitSeconds: 0),
            .conversationStop(sessionID: "child-session", close: false),
            .conversationStop(sessionID: "child-session", close: true),
        ])
    }

    @Test
    func `an empty prompt or message, or a message to itself, is refused before the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationCreate, ["prompt": " \n"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationSend, ["session_id": "child-session", "text": ""]) }
        await #expect(throws: ToolArgumentError.self) {
            _ = try await harness.run(.conversationSend, ["session_id": .string(harness.runner.sessionID), "text": "hi"])
        }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.conversationRead, ["session_id": " "]) }
        #expect(await harness.backend.calls.isEmpty)
    }

    @Test
    func `a stop cancels a read that is still waiting`() async throws {
        let cancellation = CancellationHandle()
        let started = Date()
        let read = Task {
            try await ToolRunner.untilCancelled(cancellation) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        cancellation.cancel(reason: "aborted")
        await #expect(throws: CancellationError.self) { _ = try await read.value }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: Prompt

    @Test
    func `a project's prompt explains conversations; General Chat's does not`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let project = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, mode: .confirm, skills: [], mcpServers: [])
        #expect(project.contains("# Conversations"))
        #expect(project.contains("conversation_create") && project.contains("not the user"))
        let id = UUID().uuidString
        let general = try SystemPrompt.make(
            project: ProjectIdentity(id: "temporary:" + id, name: ProjectName(id)),
            projectRoot: home.projectURL.path,
            mode: .confirm,
            skills: [],
            mcpServers: [],
        )
        #expect(!general.contains("# Conversations"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message from another conversation is marked for the app and prefixed for the model`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let seen = SeenText()
        provider.setResponses([.factory { context, _, _, _ in
            let text = context.messages.compactMap { message -> String? in
                guard case let .user(user) = message else { return nil }
                return user.content.compactMap { block -> String? in
                    if case let .text(content) = block {
                        return content.text
                    }
                    return nil
                }.joined()
            }.joined(separator: "\n")
            await seen.set(text)
            return fauxAssistantMessage("Reviewed.")
        }])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let sender = ConversationSender(sessionID: "opener-session", title: "Plan the tweak")
        try await session.prompt("Review Tweak.x", from: sender)
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.promptSubmitted(text: "Review Tweak.x", from: "opener-session")), "the app sees the text as sent, marked with the sender")
        let modelText = await seen.text
        #expect(modelText.hasPrefix(sender.prefix + "\n"), "the model reads one line naming the sender first")
        #expect(modelText.contains("Review Tweak.x"))
        #expect(sender.prefix.contains("“Plan the tweak” (opener-session)") && sender.prefix.contains("not from the user"))
        #expect(ConversationSender(sessionID: "s").prefix.contains("conversation s,"))
        await session.close()
    }
}

/// What the faux model was sent.
actor SeenText {
    var text = ""
    func set(_ value: String) {
        text = value
    }
}
