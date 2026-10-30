import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import Testing

@Suite("apelin_feedback_send is one feedbackSend request")
struct FeedbackBackendTests {
    @Test
    func `the issue goes as feedbackSend with its title and body alone`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackSend, reply: FeedbackSendResponse(number: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12"))
        let response = try await fixture.backend.sendFeedback(FeedbackToolRequest(
            context: fixture.context(),
            title: "The build log stops early",
            body: "It ends before the link step.",
        ))
        let sent = try #require(fixture.host.requests(FeedbackSendRequest.self).first)
        #expect(fixture.host.requests.map(\.operation) == [.feedbackSend])
        #expect(sent.title == "The build log stops early" && sent.body == "It ends before the link step.")
        #expect(response == FeedbackToolResponse(repository: "owngoal-dev/Apelin", issue: 12, url: "https://github.com/owngoal-dev/Apelin/issues/12"))
    }

    @Test
    func `without a GitHub sign-in it names Sign In with GitHub, by the reply's reason`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.feedbackSend) { _ in
            throw ApelinError(.denied, "no sign-in", reason: .authenticationRequired)
        }
        await #expect {
            _ = try await fixture.backend.sendFeedback(FeedbackToolRequest(context: fixture.context(), title: "T", body: "B"))
        } throws: { error in
            let message = (error as? FeedbackToolFailure)?.message ?? ""
            return message.contains("GitHub authorization is needed") && message.contains("Sign In with GitHub in Settings ▸ Git")
                && message.contains("Nothing was posted")
        }

        // Another refusal is the host's own, whatever its words say.
        fixture.host.on(.feedbackSend) { _ in
            throw ApelinError(.denied, "approval required: GitHub authorization was not given")
        }
        await #expect {
            _ = try await fixture.backend.sendFeedback(FeedbackToolRequest(context: fixture.context(), title: "T", body: "B"))
        } throws: { error in
            (error as? ApelinError)?.message.hasPrefix("approval required") == true
        }
    }

    @Test
    func `the approval carries the issue the host matches`() {
        let request = ApprovalRequest(
            id: "a", toolCallID: "c", tool: "apelin_feedback_send", arguments: "{}", workingDirectory: ".",
            projectID: "p", fingerprint: "f", reason: "Posts this title and body as a public issue.",
            detail: .feedback(FeedbackApproval(repository: "owngoal-dev/Apelin", title: "T", body: "B")),
            allowsSessionScope: false,
        )
        let payload = EventRelay.approvalPayload(request)
        let expected: ApelinCore.JSONValue = .object(["feedback": .object([
            "repository": .string("owngoal-dev/Apelin"), "title": .string("T"), "body": .string("B"),
        ])])
        #expect(payload["detail"] == expected)
        #expect(payload["allowsSessionScope"] == .bool(false))
    }
}
