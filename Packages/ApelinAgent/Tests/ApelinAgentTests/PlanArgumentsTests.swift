@testable import ApelinAgent
import enum ApelinProtocol.AgentPlanStepStatus
import struct ApelinProtocol.AgentPlan
import struct ApelinProtocol.AgentPlanStep
import Foundation
import KWWKAI
import Testing

/// What `plan_update` is sent, and the line the model reads back: the two
/// translations at the tool's edge, where a wrong argument is refused with
/// what to send instead.
@Suite("plan_update's arguments")
struct PlanArgumentsTests {
    @Test
    func `the steps are read in the order sent, pending when no status is given`() throws {
        let steps = try PlanArguments.steps(in: [
            "steps": [
                ["id": "one", "title": "Read ToolRunner"],
                ["id": "two", "title": "Change it", "status": "running"],
                ["id": "three", "title": "Build", "status": "done", "evidence": "file_read: 240 lines"],
            ],
        ])
        #expect(steps.map(\.id) == ["one", "two", "three"])
        #expect(steps.map(\.status) == [.pending, .running, .done])
        #expect(steps.map(\.title) == ["Read ToolRunner", "Change it", "Build"])
        #expect(steps[0].evidence == nil)
        #expect(steps[2].evidence == "file_read: 240 lines")
    }

    @Test
    func `what is not a plan is refused with what to send instead`() {
        let refused: [(JSONValue, String)] = [
            ([:], "needs steps"),
            (["steps": "one"], "needs steps"),
            (["steps": [["title": "No id"]]], "needs an id"),
            (["steps": [["id": "", "title": "No id"]]], "needs an id"),
            (["steps": [["id": "one"]]], "needs a title"),
            (["steps": [["id": "one", "title": ""]]], "needs a title"),
            (["steps": [["id": "one", "title": "A", "status": "half done"]]], "half done"),
            (["steps": [["id": "one", "title": "A", "status": "Done"]]], "Done"),
            (["steps": ["one"]], "object with an id"),
        ]
        for (arguments, expected) in refused {
            do {
                _ = try PlanArguments.steps(in: arguments)
                Issue.record("\(arguments) should have been refused")
            } catch let error as ToolArgumentError {
                #expect(error.message.contains(expected), "\(error.message) should say \(expected)")
            } catch {
                Issue.record("refused with \(error), not a tool argument error")
            }
        }
        // A refused status names the ones that are taken.
        do {
            _ = try PlanArguments.steps(in: ["steps": [["id": "one", "title": "A", "status": "nearly"]]])
            Issue.record("nearly is not a status")
        } catch let error as ToolArgumentError {
            for status in AgentPlanStepStatus.allCases {
                #expect(error.message.contains(status.rawValue), "the refusal names \(status.rawValue)")
            }
        } catch {
            Issue.record("refused with \(error), not a tool argument error")
        }
    }

    @Test
    func `the answer is the plan as it now stands, one line a step`() {
        let plan = AgentPlan(
            steps: [
                AgentPlanStep(id: "one", title: "Read ToolRunner", status: .done, evidence: "file_read: 240 lines"),
                AgentPlanStep(id: "two", title: "Change it", status: .running),
                AgentPlanStep(id: "three", title: "Build", status: .pending),
            ],
            revision: 2,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        )
        #expect(PlanArguments.answer(plan) == """
        Plan written: 1/3 · Change it
        [x] 1. Read ToolRunner [one] — file_read: 240 lines
        [>] 2. Change it [two]
        [ ] 3. Build [three]
        """)

        let ended = AgentPlan(
            steps: [
                AgentPlanStep(id: "a", title: "A", status: .failed, evidence: "the build stopped at a write error"),
                AgentPlanStep(id: "b", title: "B", status: .skipped, evidence: "the user settled it another way"),
            ],
            state: .cancelled,
            revision: 3,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        )
        let answer = PlanArguments.answer(ended)
        #expect(answer.hasPrefix("Plan written: 0/2 · Cancelled"))
        #expect(answer.contains("[!] 1. A [a] — the build stopped at a write error"))
        #expect(answer.contains("[-] 2. B [b] — the user settled it another way"))
    }
}
