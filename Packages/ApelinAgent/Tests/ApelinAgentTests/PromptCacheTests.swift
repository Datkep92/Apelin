@testable import ApelinAgent
import ApelinCore
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A provider caches a conversation as a prefix: the tools, then the system
/// prompt, then the messages. These hold Apelin's half of that: what a
/// session sends stays the same bytes from one request to the next, and
/// grows only at the end.
@Suite("Prompt caching")
struct PromptCacheTests {
    /// What the provider was sent, one entry per request.
    private actor Requests {
        struct Request {
            var systemPrompt: String?
            var tools: [Tool]?
            var messages: [Message]
            var sessionID: String?
        }

        private(set) var all: [Request] = []

        func add(_ context: Context, _ options: StreamOptions?) {
            all.append(Request(
                systemPrompt: context.systemPrompt,
                tools: context.tools,
                messages: context.messages,
                sessionID: options?.sessionId,
            ))
        }
    }

    /// A home with every section of the system prompt filled in: memory,
    /// a user skill, the project's instructions and a registered toolchain.
    private static func furnishedHome() throws -> TemporaryHome {
        let home = try TemporaryHome()
        _ = try EnvironmentContextTests.register(in: home)
        try home.write("AGENTS.md", "Build with apelin_project_build.")
        let skill = home.dataRoot.skills.appendingPathComponent("theme", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: theme-colours\ndescription: Use for theme work.\n---\nUse the palette.\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let store = MemoryStore(root: home.dataRoot.url)
        let snapshot = try store.save(MemoryRecord(title: "Language", body: "Reply in Chinese."), revision: store.read().revision)
        try store.save(MemoryRecord(title: "Target", body: "Hooks SpringBoard only.", projectID: home.project.id), revision: snapshot.revision)
        return home
    }

    private static func isPrefix(_ prefix: [Message], of messages: [Message]) -> Bool {
        prefix.count <= messages.count && Array(messages.prefix(prefix.count)) == prefix
    }

    @Test(.timeLimit(.minutes(1)))
    func `every request sends the same system prompt and tools, and the messages only grow, across runs and a reopen`() async throws {
        let home = try Self.furnishedHome()
        defer { home.remove() }
        let day = Calendar.current.startOfDay(for: Date())
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        func reply(_ message: AssistantMessage) -> FauxResponseStep {
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return message
            }
        }
        provider.setResponses([
            // The first run: two calls, one of them a notice, then an answer.
            reply(fauxAssistantMessage(blocks: [
                fauxToolCall(name: "file_list", arguments: ["reason": "Look at the project", "path": "."], id: "call-1"),
                fauxToolCall(name: "apelin_notification_send", arguments: ["reason": "Say it is done", "body": "The list is ready."], id: "call-2"),
            ], stopReason: .toolUse)),
            reply(fauxAssistantMessage("Listed.")),
            // The second run, after another project's memory changed.
            reply(fauxAssistantMessage("Again.")),
            // The third, from the session opened again as a new process
            // opens it.
            reply(fauxAssistantMessage("Reopened.")),
        ])
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        )
        var session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("List the project.", messageID: UUID())
        await session.waitForIdle()
        let store = MemoryStore(root: home.dataRoot.url)
        try store.save(MemoryRecord(title: "Other", body: "Not this project's.", projectID: "another-project"), revision: store.read().revision)
        // The app sends the mode it has with every message.
        await session.setApprovalMode(.confirm)
        try await session.prompt("And again.", messageID: UUID())
        await session.waitForIdle()
        let log = try await session.log.records(afterSeq: 0)
        await session.close()
        session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("Once more.", messageID: UUID())
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 4)
        guard Calendar.current.startOfDay(for: Date()) == day else { return } // the date line moved at midnight
        for (index, request) in sent.enumerated() {
            #expect(request.systemPrompt == sent[0].systemPrompt, "request \(index) sent another system prompt")
            #expect(request.tools == sent[0].tools, "request \(index) sent other tools")
            #expect(request.sessionID == configuration.id, "request \(index) has no cache key")
            if index > 0 {
                #expect(Self.isPrefix(sent[index - 1].messages, of: request.messages), "request \(index) changed what came before")
            }
        }
        // Every section that is read again for each run was there.
        let prompt = try #require(sent[0].systemPrompt)
        for section in ["Reply in Chinese.", "Hooks SpringBoard only.", "theme-colours", "Build with apelin_project_build.", "# Environment"] {
            #expect(prompt.contains(section), "the prompt has no \(section)")
        }
        #expect(sent[2].systemPrompt?.contains("Not this project's.") == false)
        // What the app is told about the run is not part of the conversation:
        // the model reads the three messages and kwwk's one tool declaration.
        #expect(log.contains {
            if case .notice = $0.event {
                true
            } else {
                false
            }
        })
        let last = try #require(sent.last).messages
        let users = last.filter {
            if case .user = $0 {
                true
            } else {
                false
            }
        }
        let declarations = last.filter {
            if case .system = $0 {
                true
            } else {
                false
            }
        }
        #expect(users.count == 3)
        #expect(declarations.count == 1, "the reopened session declared its tools again")
    }

    @Test
    func `a memory another project keeps leaves the prompt as it was, and one this chat sees changes only the memory`() throws {
        let home = try Self.furnishedHome()
        defer { home.remove() }
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .githubCopilot(model: "m"),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        )
        let root = try ScopedRoot(home.projectURL)
        let skills = SkillCatalog.load(userDirectory: home.dataRoot.skills).skills
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func prompt() -> String {
            AgentSession.systemPrompt(configuration, root: root, mode: .confirm, skills: skills, device: .current, date: date)
        }
        let before = prompt()
        #expect(prompt() == before, "the same files give the same prompt")

        let store = MemoryStore(root: home.dataRoot.url)
        var snapshot = try store.save(
            MemoryRecord(title: "Other", body: "Another project's fact.", projectID: "another-project"),
            revision: store.read().revision,
        )
        #expect(prompt() == before, "another project's memory changed this chat's prompt")
        #expect(!before.contains(snapshot.revision))

        snapshot = try store.save(MemoryRecord(title: "Editor", body: "Prefers tabs."), revision: snapshot.revision)
        let after = prompt()
        #expect(after != before)
        #expect(after.contains("Prefers tabs."))
        let memory = try #require(before.range(of: "# Long-term memory"))
        #expect(after.hasPrefix(before[..<memory.lowerBound]), "a memory changed more than the memory section")
    }

    @Test
    func `a wait on another conversation ends before the provider's cache of this one does`() {
        // Five minutes from the start of the request that asked; the model
        // takes some of them writing the call.
        #expect(ConversationReadToolRequest.maximumWaitSeconds <= 180)
    }
}
