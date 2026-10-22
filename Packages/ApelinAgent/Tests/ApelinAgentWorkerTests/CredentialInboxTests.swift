import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("The console's credential inbox: read once, stored, deleted")
struct CredentialInboxTests {
    let directory: URL
    let inbox: CredentialInbox

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apelin-inbox-\(UUID().uuidString)/credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = CredentialInbox(directory: directory)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: false, encoding: .utf8)
    }

    var remaining: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    @Test
    func `a file named for its provider is stored under that id and removed`() async throws {
        try write("github-copilot.json", #"{"access": "tid=secret", "refresh": "gho_secret", "expires": 1}"#)
        let store = DeliveredCredentialSource()
        let response = await inbox.importAll(into: store)
        #expect(response.stored == ["github-copilot"])
        #expect(response.rejected.isEmpty)
        #expect(response.available == ["github-copilot"])
        #expect(try await store.credentials(for: "github-copilot")?.refresh == "gho_secret")
        #expect(remaining.isEmpty)
    }

    @Test
    func `a kwwk auth.json map stores every provider in it`() async throws {
        try write("auth.json", #"{"github-copilot": {"access": "a", "refresh": "r", "expires": 1}, "anthropic-api-key": {"access": "k", "refresh": "", "expires": 9007199254740991, "extras": {}}}"#)
        let store = DeliveredCredentialSource()
        let response = await inbox.importAll(into: store)
        #expect(response.stored == ["anthropic-api-key", "github-copilot"])
        #expect(remaining.isEmpty)
    }

    @Test
    func `what cannot be used is removed anyway, and the answer never repeats a secret`() async throws {
        try write("github-copilot.json", #"{"token": "gho_leaked"}"#)
        try write("auth.json", #"{"someone-else": {"access": "a", "refresh": "r", "expires": 1}}"#)
        let store = DeliveredCredentialSource()
        let response = await inbox.importAll(into: store)
        #expect(response.stored.isEmpty)
        #expect(response.rejected.count == 2)
        #expect(!response.rejected.joined().contains("gho_leaked"))
        #expect(response.rejected.contains { $0.contains("someone-else") })
        #expect(remaining.isEmpty)
        #expect(await store.providerIds().isEmpty)
    }

    @Test
    func `a link is removed without being followed`() async throws {
        let target = directory.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try #"{"access": "a", "refresh": "r", "expires": 1}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("github-copilot.json"), withDestinationURL: target)
        let store = DeliveredCredentialSource()
        let response = await inbox.importAll(into: store)
        #expect(response.stored.isEmpty)
        #expect(response.rejected.first?.contains("not a regular file") == true)
        #expect(remaining.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func `an oversized file is refused and removed`() async throws {
        try write("github-copilot.json", String(repeating: " ", count: CredentialInbox.maximumFileBytes + 1))
        let response = await inbox.importAll(into: DeliveredCredentialSource())
        #expect(response.rejected.first?.contains("64 KiB") == true)
        #expect(remaining.isEmpty)
    }

    @Test
    func `no inbox folder is an empty inbox`() async {
        let response = await CredentialInbox(directory: directory.appendingPathComponent("absent")).importAll(into: DeliveredCredentialSource())
        #expect(response == .init())
    }

    @Test
    func `the inbox lives in the console's inbox folder in mobile's data folder`() {
        #expect(CredentialInbox(home: "/var/mobile").directory.path == "/var/mobile/Documents/wiki.qaq.apelin/console/inbox/credentials")
    }
}

@Suite("The relay from session events to task events")
struct EventRelayMappingTests {
    @Test
    func `an approval request puts the task in waitingForApproval until it is resolved`() {
        var waiting = 0
        let request = ApprovalRequest(
            id: "approval-1", toolCallID: "call-1", tool: "run_code", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "asks", detail: .command(.argv(["make"])), allowsSessionScope: true,
        )
        let asked = EventRelay.events(for: .approvalRequested(request), waiting: &waiting)
        #expect(asked.map(\.0) == ["approvalRequested", "state"])
        #expect(asked[0].1?["approvalID"]?.stringValue == "approval-1")
        #expect(asked[0].1?["tool"]?.stringValue == "run_code")
        #expect(asked[1].1?["state"]?.stringValue == "waitingForApproval")
        let resolved = EventRelay.events(for: .approvalResolved(requestID: "approval-1", decision: .approve(.once)), waiting: &waiting)
        #expect(resolved.map(\.0) == ["approvalResolved", "state"])
        #expect(resolved[1].1?["state"]?.stringValue == "running")
    }

    /// The session host reads `detail.command` and `workingDirectory` back
    /// from this event to hold a run_code approval to the command it showed
    /// (`AgentApprovals.approvedSpec` in Apelind decodes exactly this shape).
    @Test
    func `a run_code approval request carries its command in the shape the host reads`() {
        func payload(_ invocation: RunCodeInvocation, cwd: String) -> ApelinCore.JSONValue {
            let request = ApprovalRequest(
                id: "a", toolCallID: "c", tool: "run_code", arguments: "{}", workingDirectory: cwd,
                projectID: "p", fingerprint: "f", reason: "asks", detail: .command(invocation), allowsSessionScope: true,
            )
            return EventRelay.approvalPayload(request)
        }
        let argv = payload(.argv(["make", "-j2"]), cwd: "Sources")
        let argvCommand: ApelinCore.JSONValue = .object([
            "argv": .object(["_0": .array([.string("make"), .string("-j2")])]),
        ])
        #expect(argv["workingDirectory"]?.stringValue == "Sources")
        #expect(argv["detail"]?["command"] == argvCommand)
        let shell = payload(.shell("make | tail"), cwd: ".")
        let shellCommand: ApelinCore.JSONValue = .object(["shell": .object(["_0": .string("make | tail")])])
        #expect(shell["detail"]?["command"] == shellCommand)
        let script = payload(.script(interpreter: "python3", source: "print(1)"), cwd: ".")
        let scriptCommand: ApelinCore.JSONValue = .object([
            "script": .object(["interpreter": .string("python3"), "source": .string("print(1)")]),
        ])
        #expect(script["detail"]?["command"] == scriptCommand)
        // And the agent sends shell text to the host as an sh script.
        let sent = ChannelHostBackend.spec(.shell("make | tail"))
        #expect(sent == RunCodeSpec.script(interpreter: "sh", source: "make | tail"))
    }

    /// The session host reads `detail.packageRemoval.installationID` back
    /// from this event to grant the removal once
    /// (`AgentApprovals.recordInLedger` in Apelind; the session host's test
    /// relays exactly this payload).
    @Test
    func `a package removal request carries its installation in the shape the host reads`() throws {
        let root = try ScopedRoot(URL(fileURLWithPath: NSTemporaryDirectory()))
        let verdict = ApprovalPolicy(mode: .confirm).evaluate(
            InvocationFacts(tool: .local(.removePackage), installationID: "inst-1"),
            root: root,
        )
        guard case let .ask(reason, detail) = verdict else {
            Issue.record("package removal must ask under Confirm, got \(verdict)")
            return
        }
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "remove_package", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: reason, detail: detail, allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object([
            "packageRemoval": .object(["installationID": .string("inst-1")]),
        ])
        #expect(payload["tool"]?.stringValue == "remove_package")
        #expect(payload["detail"] == expected)
    }

    @Test
    func `the provider defaults to Copilot with Claude Sonnet`() throws {
        let configuration = try AgentWorker.provider(.init(projectName: "Hello"))
        #expect(configuration == .githubCopilot(model: "claude-sonnet-5.5"))
        #expect(try AgentWorker.provider(.init(provider: .anthropic, model: "m")) == .anthropic(model: "m", oauth: false))
        #expect(throws: (any Error).self) { try AgentWorker.provider(.init(provider: .openAICompatible)) }
        // Every other login is kwwk's stored provider of its id, with kwwk's
        // default model unless one is named.
        #expect(try AgentWorker.provider(.init(provider: .kimiCoding)) == .stored(storeID: "kimi-coding", model: nil))
        #expect(try AgentWorker.provider(.init(provider: .openAICodex, model: "gpt-5")) == .stored(storeID: "openai-codex", model: "gpt-5"))
        #expect(try AgentWorker.provider(.init(provider: .google, model: "")) == .stored(storeID: "google-api-key", model: nil))
    }

    @Test
    func `the fallback digest covers the build description and nothing else`() throws {
        let project = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let manifest = project.appendingPathComponent("apelin-project.json")
        try #"{"products": [1], "build": {"steps": []}, "package": {"id": "a"}}"#.write(to: manifest, atomically: true, encoding: .utf8)
        let first = try HostDigestLedger.digest(of: .build, projectURL: project)
        try #"{"package": {"id": "b"}, "build": {"steps": []}, "products": [1]}"#.write(to: manifest, atomically: true, encoding: .utf8)
        #expect(try HostDigestLedger.digest(of: .build, projectURL: project) == first)
        #expect(try HostDigestLedger.digest(of: .packaging, projectURL: project) != first)
    }
}
