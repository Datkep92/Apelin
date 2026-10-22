@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Scripted session")
struct ScriptedSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func `a greeting leaves a placeholder available for a later project goal`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let metadata = #"{"displayName":"\#(home.project.name.rawValue)","autoName":true}"#
        try home.write("apelin-project.json", metadata)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        provider.setResponses([.message(fauxAssistantMessage(#"{"title":"Greeting","projectName":null}"#))])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ),
        backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        var events = try await session.events(afterSeq: 0)
        await session.generateTitle(for: "Hello")
        for await record in events {
            if case .titleUpdated = record.event {
                break
            }
        }
        // Closing the first stream does not affect the independent session.
        var records = try await session.log.records(afterSeq: 0)
        let after = try #require(records.last?.seq)
        provider.setResponses([.message(fauxAssistantMessage(#"{"title":"Build a widget","projectName":"Weather Widget"}"#))])
        events = try await session.events(afterSeq: after)
        // The first request's task finalizer is actor-queued after its title.
        await Task.yield()
        await session.generateTitle(for: "Build a weather widget in this project")
        for await record in events {
            if case .projectNameSuggested = record.event {
                break
            }
        }
        records = try await session.log.records(afterSeq: 0)
        #expect(records.filter {
            if case .titleUpdated = $0.event {
                true
            } else {
                false
            }
        }.count == 1)
        #expect(records.contains { $0.event == .projectNameSuggested("Weather Widget") })
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func `only a semantic project-name candidate can rename a placeholder`(_ hasProjectIntent: Bool) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let result = hasProjectIntent
            ? #"{"title":"Build a weather widget","projectName":"Weather Widget"}"#
            : #"{"title":"Greeting","projectName":null}"#
        provider.setResponses([.message(fauxAssistantMessage(result))])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ),
        backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let events = try await session.events(afterSeq: 0)
        await session.generateTitle(for: hasProjectIntent ? "Build a weather widget for this project" : "Hello")
        for await record in events {
            if case .titleUpdated = record.event {
                break
            }
        }
        let records = try await session.log.records(afterSeq: 0)
        let names = records.compactMap { record -> String? in
            if case let .projectNameSuggested(name) = record.event {
                return name
            }
            return nil
        }
        #expect(names == (hasProjectIntent ? ["Weather Widget"] : []))
        #expect(try await session.log.readTranscript().isEmpty)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `titles use the current model without entering the conversation`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let original = await registerFauxProvider()
        let selected = await registerFauxProvider()
        defer { original.unregister(); selected.unregister() }
        selected.setResponses([.message(fauxAssistantMessage("\"Inspect the title view\""))])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(
            project: home.project, provider: .registered(original.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        ),
        backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.configure(provider: .registered(selected.getModel()), thinking: .off, credentials: DeliveredCredentialSource())
        let events = try await session.events(afterSeq: 0)
        await session.generateTitle(for: "Inspect the title view and explain its layout")
        var title: String?
        for await record in events {
            if case let .titleUpdated(value) = record.event {
                title = value; break
            }
        }
        #expect(title == "Inspect the title view")
        #expect(try await session.log.readTranscript().isEmpty)
        await session.close()
    }

    @Test
    func `patch_file → build → install → confirm_loaded through a mock host`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("Sources/Tweak.m", "static BOOL enabled = NO;\n")

        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [
                fauxText("Enabling the hook."),
                fauxToolCall(name: "patch_file", arguments: ["reason": "Turn the hook on", "path": "Sources/Tweak.m", "old_text": "enabled = NO", "new_text": "enabled = YES"]),
            ], stopReason: .toolUse)),
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "build", arguments: ["reason": "Build it", "configuration": "debug"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "install", arguments: ["reason": "Install it", "artifact_id": "artifact-1", "artifact_digest": "deb-digest-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "confirm_loaded", arguments: ["reason": "Check it loaded", "build_id": "build-1", "target": "SpringBoard"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Installed and loaded in SpringBoard.")),
        ])

        let ledger = MockDigestLedger()
        await ledger.change(.packaging, to: "packaging-with-postinst")
        let backend = MockBackend()
        let configuration = AgentSessionConfiguration(
            project: home.project,
            provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .confirm),
            dataRoot: home.dataRoot,
        )
        let session = try await AgentSession(configuration: configuration, backend: backend, digests: ledger, credentials: DeliveredCredentialSource())

        // Play the app: watch events, approve what is asked, host records.
        let stream = try await session.events(afterSeq: 0)
        let app = Task { () -> [SessionEventRecord] in
            var seen: [SessionEventRecord] = []
            for await record in stream {
                seen.append(record)
                if case let .approvalRequested(request) = record.event {
                    await ledger.record(request, decision: .approve(.once))
                    try? await session.approve(requestID: request.id, decision: .approve(.once))
                }
                if case .finished = record.event {
                    break
                }
            }
            return seen
        }

        try await session.prompt("Turn the hook on, build, install and check it loaded.")
        let records = await app.value
        await session.waitForIdle()

        #expect(try home.read("Sources/Tweak.m") == "static BOOL enabled = YES;\n")
        let calls = await backend.calls
        #expect(calls.count == 3)
        guard calls.count == 3 else { return }
        #expect(calls[0] == .build(digest: "build-template", evidence: .templateMatch(digest: "build-template")))
        guard case .install("artifact-1", "deb-digest-1", "packaging-with-postinst", .user) = calls[1] else {
            Issue.record("install should be user-approved and digest-bound: \(calls[1])"); return
        }
        #expect(calls[2] == .confirmLoaded(build: "build-1", target: "SpringBoard"))

        let events = records.map(\.event)
        #expect(records.map(\.seq) == Array(1 ... UInt64(records.count)))
        #expect(events.first == .promptSubmitted(text: "Turn the hook on, build, install and check it loaded."))
        let toolOrder = events.compactMap { event -> String? in
            switch event {
            case let .toolCallStarted(call): "start:\(call.name)"
            case let .toolCallFinished(result): "end:\(result.name)\(result.isError ? ":error" : "")"
            case let .approvalRequested(request): "ask:\(request.tool)"
            case .approvalResolved: "resolved"
            default: nil
            }
        }
        // The reason reaches the app with the call, and the file tool's
        // first line ends with the lines it added and removed.
        let patchCall = events.compactMap { event -> ToolCallRecord? in
            if case let .toolCallStarted(call) = event, call.name == "patch_file" {
                return call
            }
            return nil
        }.first
        #expect(patchCall?.arguments.contains("Turn the hook on") == true)
        let patchResult = events.compactMap { event -> ToolResultRecord? in
            if case let .toolCallFinished(result) = event, result.name == "patch_file" {
                return result
            }
            return nil
        }.first
        #expect(patchResult?.output.split(separator: "\n").first?.hasSuffix("(1 replacement, +1 -1)") == true)
        #expect(toolOrder == [
            "start:patch_file", "end:patch_file",
            "start:build", "end:build",
            "start:install", "ask:install", "resolved", "end:install",
            "start:confirm_loaded", "end:confirm_loaded",
        ])
        #expect(events.contains(.messageFinished(text: "Installed and loaded in SpringBoard.")))
        #expect(events.last == .finished(reason: .completed))

        let lastSeq = await session.log.lastSeq
        await session.close()

        // A new process on the same id resumes: the transcript is there,
        // the sequence continues, and a reattaching app gets only what is
        // new.
        faux.setResponses([.message(fauxAssistantMessage("Still loaded."))])
        let resumed = try await AgentSession(configuration: configuration, backend: backend, digests: ledger, credentials: DeliveredCredentialSource())
        let transcript = try await resumed.log.readTranscript()
        #expect(transcript.count >= 9)
        let replay = try await resumed.events(afterSeq: lastSeq)
        try await resumed.prompt("Is it still loaded?")
        var tail: [SessionEventRecord] = []
        for await record in replay {
            tail.append(record)
            if case .finished = record.event {
                break
            }
        }
        #expect(tail.first?.seq == lastSeq + 1)
        #expect(tail.contains { $0.event == .messageFinished(text: "Still loaded.") })
        await resumed.close()
    }

    @Test
    func `abort while an approval waits ends the run as aborted`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "remove_package", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("never reached")),
        ])
        let backend = MockBackend()
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: backend,
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        var sawFinish: FinishReason?
        for await record in stream {
            if case .approvalRequested = record.event {
                await session.abort()
            }
            if case let .finished(reason) = record.event {
                sawFinish = reason; break
            }
        }
        #expect(sawFinish == .aborted)
        #expect(await backend.calls.isEmpty)
        #expect(await session.pendingApprovals.isEmpty)
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message sent during a run joins it after the tool call in progress`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "remove_package", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Removed, and noted.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        let later = UUID()
        var events: [AgentSessionEvent] = []
        for await record in stream {
            events.append(record.event)
            if case let .approvalRequested(request) = record.event {
                try await session.prompt("and keep the logs", messageID: later)
                try await session.approve(requestID: request.id, decision: .approve(.once))
            }
            if case .finished = record.event {
                break
            }
        }
        let queuedAt = events.firstIndex {
            if case .userMessageQueued(later, "and keep the logs", _) = $0 {
                true
            } else {
                false
            }
        }
        let takenAt = events.firstIndex {
            if case .userMessage(later, "and keep the logs", _) = $0 {
                true
            } else {
                false
            }
        }
        let toolDoneAt = events.firstIndex {
            if case .toolCallFinished = $0 {
                true
            } else {
                false
            }
        }
        #expect(queuedAt != nil && takenAt != nil && toolDoneAt != nil)
        if let queuedAt, let takenAt, let toolDoneAt {
            #expect(queuedAt < toolDoneAt && toolDoneAt < takenAt, "\(events)")
        }
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message queued when the run is stopped is dropped`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "remove_package", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("never reached")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        let later = UUID()
        var dropped: [UUID] = []
        for await record in stream {
            if case .approvalRequested = record.event {
                try await session.prompt("and keep the logs", messageID: later)
                await session.abort()
            }
            if case let .queuedMessagesDropped(ids) = record.event {
                dropped = ids
            }
            if case .finished = record.event {
                break
            }
        }
        #expect(dropped == [later])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a message queued when the run fails is dropped and never reaches the next run`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let entered = AsyncStream<Void>.makeStream()
        let queued = AsyncStream<Void>.makeStream()
        let seen = SeenText()
        faux.setResponses([
            .factory { _, _, _, _ in
                entered.continuation.yield()
                for await _ in queued.stream {
                    break
                }
                return fauxAssistantMessage("", stopReason: .error, errorMessage: "400 invalid_request_error: malformed request")
            },
            .factory { context, _, _, _ in
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
                return fauxAssistantMessage("Started over.")
            },
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("build it", messageID: UUID())
        for await _ in entered.stream {
            break
        }
        let later = UUID()
        try await session.prompt("and keep the logs", messageID: later)
        queued.continuation.yield()
        var dropped: [UUID] = []
        var finished: [FinishReason] = []
        for await record in stream {
            if case let .queuedMessagesDropped(ids) = record.event {
                dropped = ids
            }
            if case let .finished(reason) = record.event {
                finished.append(reason)
                if finished.count == 1 {
                    try await session.prompt("start over", messageID: UUID())
                } else {
                    break
                }
            }
        }
        #expect(finished == [.failed, .completed])
        #expect(dropped == [later])
        let modelText = await seen.text
        #expect(modelText.contains("start over"))
        #expect(!modelText.contains("and keep the logs"), "the dropped message stayed in the steering queue: \(modelText)")
        await session.close()
    }

    @Test
    func `a session without credentials does not open, and reads no environment`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        await #expect(throws: ProviderResolutionError.missingCredentials("github-copilot")) {
            _ = try await AgentSession(
                configuration: AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "claude-sonnet-5.5"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot),
                backend: MockBackend(),
                digests: MockDigestLedger(),
                credentials: DeliveredCredentialSource(),
            )
        }
    }
}
