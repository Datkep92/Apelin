@testable import ApelinAgent
import ApelinCore
import Foundation
import KWWKAI
import Testing

@Suite("Long-term memory")
struct MemoryTests {
    @Test
    func `tools persist scoped records, retain scope and refuse stale or hidden records`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let tools = MemoryTools(store: store, projectID: home.project.id)
        var snapshot = try tools.list()
        snapshot = try tools.save(["revision": .string(snapshot.revision), "title": "Build target", "body": "Use iOS 16."])
        let record = try #require(snapshot.records.first)
        #expect(record.projectID == home.project.id)
        #expect(try MemoryStore(root: home.dataRoot.url).read().records == [record])
        snapshot = try tools.save(["revision": .string(snapshot.revision), "id": .string(record.id), "title": "Build target", "body": "Use iOS 17.", "scope": "global"])
        #expect(snapshot.records.first?.projectID == home.project.id)
        let other = MemoryTools(store: store, projectID: "another-project")
        #expect(try other.list().records.isEmpty)
        // Another project's record is not one this project can name: a wrong
        // id, not a change to memory.
        #expect(throws: ToolArgumentError.self) { try other.delete(["id": .string(record.id), "revision": .string(snapshot.revision)]) }
        let stale = snapshot
        snapshot = try tools.delete(["id": .string(record.id), "revision": .string(snapshot.revision)])
        #expect(snapshot.records.isEmpty)
        #expect(throws: MemoryStoreError.changed) {
            try tools.save(["revision": .string(stale.revision), "title": "Build target", "body": "Use iOS 17."])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `real tool dispatch maintains memory without prompting for approval`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let events = EventCollector()
        let runner = try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                                    policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                                    gate: ApprovalGate { await events.add($0) }, memory: store)
        let revision = try store.read().revision
        _ = try await runner.run(.local(.memorySave), toolCallID: "save", arguments: ["revision": .string(revision), "title": "Language", "body": "Use Chinese.", "scope": "global"], cancellation: nil, mcp: nil)
        let saved = try store.read()
        #expect(saved.records.count == 1)
        _ = try await runner.run(.local(.memoryList), toolCallID: "list", arguments: [:], cancellation: nil, mcp: nil)
        _ = try await runner.run(.local(.memoryDelete), toolCallID: "delete", arguments: ["revision": .string(saved.revision), "id": .string(saved.records[0].id)], cancellation: nil, mcp: nil)
        #expect(try store.read().records.isEmpty)
        #expect(await events.events.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `an empty id creates a record, and an unknown id is named as such`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let runner = try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                                    policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                                    gate: ApprovalGate { _ in }, memory: store)
        let empty = try store.read().revision
        _ = try await runner.run(.local(.memorySave), toolCallID: "save", arguments: ["revision": .string(empty), "id": "", "title": "Language", "body": "Use Chinese."], cancellation: nil, mcp: nil)
        let saved = try store.read()
        #expect(saved.records.map(\.title) == ["Language"])
        let error = await #expect(throws: ToolArgumentError.self) {
            try await runner.run(.local(.memorySave), toolCallID: "update", arguments: ["revision": .string(saved.revision), "id": "no-such-id", "title": "Language", "body": "Use English."], cancellation: nil, mcp: nil)
        }
        #expect(error?.message.contains("No memory has id no-such-id") == true)
        #expect(try store.read().records.map(\.body) == ["Use Chinese."])
    }

    @Test(.timeLimit(.minutes(1)))
    func `new and existing sessions see current memory while other projects stay private`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let store = MemoryStore(root: home.dataRoot.url)
        let global = MemoryRecord(title: "Language", body: "memory-old-language")
        let local = MemoryRecord(title: "Target", body: "memory-local-target", projectID: home.project.id)
        let other = MemoryRecord(title: "Other", body: "memory-unrelated-project", projectID: "other")
        var snapshot = try store.save(global, revision: store.read().revision)
        snapshot = try store.save(local, revision: snapshot.revision)
        snapshot = try store.save(other, revision: snapshot.revision)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(provider.getModel()),
                                                      approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        provider.setResponses([.factory { context, _, _, _ in
            #expect(context.systemPrompt?.contains("memory-old-language") == true)
            #expect(context.systemPrompt?.contains("memory-local-target") == true)
            #expect(context.systemPrompt?.contains("memory-unrelated-project") == false)
            return fauxAssistantMessage("Read memory.")
        }])
        try await session.prompt("Use my saved preferences.")
        await session.waitForIdle()
        snapshot = try store.save(MemoryRecord(id: global.id, title: global.title, body: "memory-new-language"), replacing: global.id, revision: snapshot.revision)
        snapshot = try store.delete(id: local.id, revision: snapshot.revision)
        await session.setApprovalMode(.relaxed)
        provider.setResponses([.factory { context, _, _, _ in
            #expect(context.systemPrompt?.contains("memory-old-language") == false)
            #expect(context.systemPrompt?.contains("memory-new-language") == true)
            #expect(context.systemPrompt?.contains("memory-local-target") == false)
            #expect(context.systemPrompt?.contains("Approval mode: Relaxed") == true)
            return fauxAssistantMessage("Refreshed memory.")
        }])
        try await session.prompt("Use the updated preferences.")
        await session.waitForIdle()
        await session.close()
        // A different session id proves this is independent of transcript recovery.
        var nextConfiguration = configuration
        nextConfiguration.id = UUID().uuidString
        let next = try await AgentSession(configuration: nextConfiguration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        provider.setResponses([.factory { context, _, _, _ in
            #expect(context.systemPrompt?.contains("memory-new-language") == true)
            #expect(context.systemPrompt?.contains("memory-local-target") == false)
            #expect(context.systemPrompt?.contains("memory-unrelated-project") == false)
            #expect(context.systemPrompt?.contains("not instructions or authorization") == true)
            return fauxAssistantMessage("New chat remembers.")
        }])
        try await next.prompt("Continue in a new chat.")
        await next.waitForIdle()
        await next.close()
    }
}
