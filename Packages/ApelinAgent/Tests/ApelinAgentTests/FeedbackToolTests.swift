@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

@Suite("apelin_feedback_send")
struct FeedbackToolTests {
    private static let arguments: JSONValue = ["title": "  The build log stops early ", "body": "It ends before the link step."]
    private static let issue = FeedbackApproval(
        repository: "owngoal-dev/Apelin",
        title: "The build log stops early",
        body: "It ends before the link step.",
    )

    @Test
    func `every chat offers it, as a system tool that takes a title, a body and a reason`() throws {
        let tool = AgentToolName.feedbackSend
        #expect(tool.rawValue == "apelin_feedback_send")
        #expect(tool.risk == .system)
        #expect(!tool.isProjectOnly)
        guard case let .object(schema) = ToolReason.adding(to: tool.parameters), case let .array(names)? = schema["required"] else {
            Issue.record("no required arguments"); return
        }
        let required = names.compactMap { name -> String? in
            if case let .string(text) = name {
                return text
            }
            return nil
        }
        #expect(Set(required) == ["title", "body", "reason"])
        #expect(tool.summary.contains("never on your own"), "only when the user asks or agrees")
        #expect(tool.summary.contains("Settings ▸ Git"))

        let home = try TemporaryHome()
        defer { home.remove() }
        let general = try ToolRunner(
            sessionID: UUID().uuidString,
            project: ProjectIdentity(id: "temporary:\(UUID().uuidString)", name: home.project.name),
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        ).agentTools(mcp: []).map(\.name)
        #expect(general.contains("apelin_feedback_send"), "General Chat too")
    }

    @Test
    func `Strict asks for every issue, showing it whole, and never for the session`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let (result, first) = try await harness.run(.feedbackSend, Self.arguments, answering: .approve(.session))
        let request = try #require(first.first)
        #expect(first.count == 1)
        #expect(request.tool == "apelin_feedback_send")
        #expect(request.detail == .feedback(Self.issue), "the text sent, the title trimmed")
        #expect(!request.allowsSessionScope)
        #expect(request.reason.contains("public issue on owngoal-dev/Apelin"))
        #expect(!ToolRunner.allowsSessionScope(.local(.feedbackSend), detail: .none))

        // Even after a "for this session" answer, the same issue asks again.
        let (_, second) = try await harness.run(.feedbackSend, Self.arguments)
        #expect(second.count == 1)

        let sent = await harness.backend.calls.compactMap { call -> String? in
            guard case let .feedback(title, body, evidence) = call else { return nil }
            guard case .user = evidence else { return "not the user's" }
            return title + " / " + body
        }
        #expect(sent == ["The build log stops early / It ends before the link step.", "The build log stops early / It ends before the link step."])
        guard case let .text(text)? = result.content.first else {
            Issue.record("no answer"); return
        }
        #expect(text.text.contains("https://github.com/owngoal-dev/Apelin/issues/7"))
    }

    @Test
    func `Relaxed and Full send it without asking, as they push`() async throws {
        for mode in [ApprovalMode.relaxed, .full] {
            let harness = try DigestApprovalTests.Harness(mode: mode)
            defer { harness.home.remove() }
            let (_, asked) = try await harness.run(.feedbackSend, Self.arguments)
            #expect(asked.isEmpty, "\(mode)")
            #expect(await harness.backend.calls == [.feedback(title: Self.issue.title, body: Self.issue.body, evidence: .relaxed)])
        }
    }

    @Test
    func `a text Apelin would refuse is refused before anyone is asked`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let refused: [JSONValue] = [
            ["title": "", "body": "Body"],
            ["title": "Two\nlines", "body": "Body"],
            ["title": "Title", "body": "From 192.168.1.20"],
            ["title": "Title", "body": "Saved in /var/mobile/Documents/wiki.qaq.apelin/Projects/Secret"],
            ["title": "Title", "body": .string("token ghp_" + String(repeating: "A1b2", count: 9))],
        ]
        for arguments in refused {
            await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.feedbackSend, arguments) }
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty, "nothing is asked")
    }
}
