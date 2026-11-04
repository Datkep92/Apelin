@testable import ApelinProtocol
import Foundation
import XCTest

/// The plan the assistant carries out: the rules a plan is written under,
/// what a plan says about itself, and the request the conversation's plan
/// bar sends. A plan lives in the session's event log, so a step already
/// written has to read the same way after a restart and an earlier release's
/// log has to read at all.
final class AgentPlanTests: XCTestCase {
    private func step(
        _ id: String,
        _ title: String,
        _ status: AgentPlanStepStatus = .pending,
        evidence: String? = nil,
    ) -> AgentPlanStep {
        AgentPlanStep(id: id, title: title, status: status, evidence: evidence)
    }

    private func plan(
        _ steps: [AgentPlanStep],
        state: AgentPlanState = .active,
        revision: Int = 1,
    ) -> AgentPlan {
        AgentPlan(
            steps: steps,
            state: state,
            revision: revision,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        )
    }

    /// The message a refused plan is refused with: it is what the model is
    /// told, so a refusal that says nothing is a bug in itself.
    private func refusal(
        _ steps: [AgentPlanStep],
        file: StaticString = #filePath,
        line: UInt = #line,
    ) -> String {
        do {
            _ = try AgentPlanRules.validate(steps)
            XCTFail("the plan should have been refused", file: file, line: line)
            return ""
        } catch let violation as AgentPlanViolation {
            XCTAssertFalse(violation.message.isEmpty, "a refusal says what to send instead", file: file, line: line)
            return violation.message
        } catch {
            XCTFail("refused with \(error), not a plan violation", file: file, line: line)
            return ""
        }
    }

    func testEveryRuleIsRefusedWithWhatToSendInstead() throws {
        XCTAssertEqual(try AgentPlanRules.validate([step("one", "First"), step("two", "Second")]).count, 2)
        XCTAssertTrue(refusal([]).contains("at least one step"), "an empty plan is nothing to carry out")

        let cap = AgentPlanRules.maximumSteps
        let many = (1 ... cap + 1).map { step("s\($0)", "Step \($0)") }
        XCTAssertTrue(refusal(many).contains("\(cap)"), "the refusal names the cap")
        XCTAssertEqual(try AgentPlanRules.validate(Array(many.prefix(cap))).count, cap, "a plan at the cap is taken")

        XCTAssertTrue(refusal([step("one", "First"), step("one", "Again")]).contains("share the id"))
        XCTAssertTrue(refusal([step("one", "A", .running), step("two", "B", .running)]).contains("running"))
        XCTAssertTrue(refusal([step("one", "Two\nlines")]).contains("one line"))
        XCTAssertTrue(refusal([step("  ", "A")]).contains("id"))
        XCTAssertTrue(refusal([step("one\n2", "A")]).contains("id"))
        XCTAssertTrue(refusal([step("one", String(repeating: "x", count: AgentPlanRules.maximumTitleCharacters + 1))])
            .contains("\(AgentPlanRules.maximumTitleCharacters)"))
        XCTAssertTrue(refusal([step(String(repeating: "x", count: AgentPlanRules.maximumIDCharacters + 1), "A")])
            .contains("\(AgentPlanRules.maximumIDCharacters)"))
        XCTAssertTrue(
            refusal([step("one", "A", .failed, evidence: String(repeating: "x", count: AgentPlanRules.maximumEvidenceCharacters + 1))])
                .contains("\(AgentPlanRules.maximumEvidenceCharacters)"),
        )
    }

    func testWhatAPlanKeepsIsTrimmedAndEmptyEvidenceIsNone() throws {
        let written = try AgentPlanRules.validate([
            step("  one  ", "  Read the settings  ", .done, evidence: "  file_read: 40 lines  "),
            step("two", "Change them", .pending, evidence: "   "),
        ])
        XCTAssertEqual(written.map(\.id), ["one", "two"])
        XCTAssertEqual(written[0].title, "Read the settings")
        XCTAssertEqual(written[0].evidence, "file_read: 40 lines")
        XCTAssertNil(written[1].evidence, "whitespace is not evidence")
    }

    func testAStepThatEndedStaysEnded() {
        XCTAssertNil(AgentPlanRules.refusesChange(from: .pending, to: .running))
        XCTAssertNil(AgentPlanRules.refusesChange(from: .running, to: .done))
        XCTAssertNil(AgentPlanRules.refusesChange(from: .done, to: .done), "a step re-sent as done is the step it was")
        XCTAssertNil(AgentPlanRules.refusesChange(from: .failed, to: .failed))
        let moves: [(AgentPlanStepStatus, AgentPlanStepStatus)] = [
            (.done, .pending), (.done, .failed), (.failed, .running), (.skipped, .done),
        ]
        for (from, to) in moves {
            let refusal = AgentPlanRules.refusesChange(from: from, to: to)
            XCTAssertNotNil(refusal, "\(from.rawValue) to \(to.rawValue) is not a step back")
            XCTAssertTrue(refusal?.contains(from.rawValue) ?? false, "the refusal names \(from.rawValue)")
        }
        XCTAssertTrue(AgentPlanStepStatus.done.isSettled)
        XCTAssertTrue(AgentPlanStepStatus.skipped.isSettled)
        XCTAssertFalse(AgentPlanStepStatus.running.isSettled)
        XCTAssertFalse(AgentPlanStepStatus.pending.isSettled)
    }

    func testEvidenceNamesWholeToolNamesOnly() {
        let known: Set<String> = ["file_read", "file_edit", "shell_run"]
        XCTAssertEqual(AgentPlanRules.tools(in: "file_read: showed ToolRunner.swift, 240 lines", known: known), ["file_read"])
        XCTAssertEqual(AgentPlanRules.tools(in: "file_reader is not file_read", known: known), ["file_read"],
                       "a name is a whole word")
        XCTAssertEqual(AgentPlanRules.tools(in: "file_read, then file_edit and file_read again", known: known),
                       ["file_read", "file_edit"], "each name once, in the order read")
        XCTAssertEqual(AgentPlanRules.tools(in: "shell_run — exit 0", known: known), ["shell_run"])
        XCTAssertEqual(AgentPlanRules.tools(in: "it worked", known: known), [], "a belief is not a tool")
    }

    func testTheCountsAndTheStepBeingDoneNow() {
        let mixed = plan([
            step("a", "A", .done, evidence: "file_read: A"),
            step("b", "B", .running),
            step("c", "C"),
        ])
        XCTAssertEqual(mixed.doneCount, 1)
        XCTAssertEqual(mixed.settledCount, 1)
        XCTAssertEqual(mixed.currentStep?.id, "b", "the step being done now, not a step that ended")
        XCTAssertFalse(mixed.isFinished)

        let afterFailure = plan([
            step("a", "A", .done, evidence: "x"),
            step("b", "B", .failed, evidence: "y"),
            step("c", "C"),
        ])
        XCTAssertEqual(afterFailure.currentStep?.id, "c", "a step that failed is not the one being done now")
        XCTAssertEqual(afterFailure.toldStep?.id, "c", "a reader is told about the step still to come")
        XCTAssertEqual(afterFailure.settledCount, 2)

        let failedLast = plan([
            step("a", "A", .done, evidence: "file_read: A"),
            step("b", "B", .failed, evidence: "the build stopped"),
        ])
        XCTAssertNil(failedLast.currentStep)
        XCTAssertEqual(failedLast.toldStep?.id, "b", "nothing is left to do, so the step that failed is what is told")

        let finished = plan([
            step("a", "A", .done, evidence: "x"),
            step("b", "B", .skipped, evidence: "not needed"),
        ])
        XCTAssertTrue(finished.isFinished)
        XCTAssertEqual(finished.doneCount, 1)
        XCTAssertEqual(finished.settledCount, 2)
        XCTAssertNil(finished.currentStep)
        XCTAssertNil(finished.toldStep, "a skipped step is the user's own ending, not something to be told at the top")
        XCTAssertFalse(plan([]).isFinished, "a plan with no step is not a finished one")
    }

    func testTheProgressLineSaysWhereTheWorkIs() {
        let active = plan([
            step("a", "A", .done, evidence: "x"),
            step("b", "B", .running),
            step("c", "C"),
        ])
        XCTAssertEqual(active.progressLine, "1/3 · B", "the line names the step being done")
        XCTAssertEqual(plan([
            step("a", "A", .done, evidence: "x"),
            step("b", "B", .failed, evidence: "y"),
            step("c", "C"),
        ]).progressLine, "1/3 · Next: C")
        XCTAssertEqual(plan([step("a", "A", .done, evidence: "x"), step("c", "C")], state: .paused).progressLine, "1/2 · Paused")
        XCTAssertEqual(plan([step("a", "A", .done, evidence: "x"), step("c", "C")], state: .cancelled).progressLine, "1/2 · Cancelled")
        // A plan with nothing left to do but a step that failed is not a
        // finished one: the line says what did not work.
        XCTAssertEqual(plan([
            step("a", "A", .done, evidence: "file_read: A"),
            step("b", "B", .failed, evidence: "the build stopped"),
        ]).progressLine, "1/2 · Failed: B")
        XCTAssertEqual(plan([
            step("a", "A", .done, evidence: "x"),
            step("b", "B", .skipped, evidence: "not needed"),
        ]).progressLine, "1/2 · Finished")
    }

    func testThePromptBlockIsWhatTheNextTurnReads() {
        let block = plan([
            step("one", "Read the settings", .done, evidence: "file_read: 40 lines"),
            step("two", "Change them", .running),
        ]).promptBlock
        XCTAssertEqual(block, """
        - Plan (1/2 · Change them):
          1. [done] Read the settings — file_read: 40 lines
          2. [running] Change them
        """)
        let paused = plan([step("one", "A")], state: .paused).promptBlock
        XCTAssertTrue(paused.hasPrefix("- Plan (0/1 · Paused):"))
        XCTAssertTrue(paused.contains("The user paused this plan"), "a paused plan says so where the model reads it")
    }

    func testTheNamesAnEarliereReleaseWroteStillRead() throws {
        XCTAssertEqual(AgentPlan.eventKind, "plan", "the app's reader matches the event by this kind")
        XCTAssertEqual(AgentPlanStepStatus.allCases.map(\.rawValue), ["pending", "running", "done", "failed", "skipped"])
        let line = #"{"id":"one","title":"A","status":"done","evidence":"file_read: 10 lines"}"#
        let decoded = try JSONDecoder().decode(AgentPlanStep.self, from: Data(line.utf8))
        XCTAssertEqual(decoded.id, "one")
        XCTAssertEqual(decoded.status, .done)
        XCTAssertEqual(decoded.evidence, "file_read: 10 lines")
        XCTAssertEqual(try JSONDecoder().decode(AgentPlan.self, from: Data(#"{"steps":[],"state":"paused","revision":2,"updatedAt":0}"#.utf8)).state,
                       .paused)
    }

    func testAPlanAndItsRequestRoundTrip() throws {
        let written = plan([
            step("one", "A", .done, evidence: "file_read: 10 lines"),
            step("two", "B", .running),
        ], state: .paused, revision: 3)
        let read = try JSONDecoder().decode(AgentPlan.self, from: try JSONEncoder().encode(written))
        XCTAssertEqual(read, written)
        XCTAssertEqual(read.steps[0].evidence, "file_read: 10 lines")

        XCTAssertEqual(AgentPlanAction.allCases.count, 4)
        XCTAssertEqual(AgentPlanRequest.operation, .agentPlan)
        let reading = AgentPlanRequest(sessionID: "s1")
        XCTAssertNil(reading.action, "no action only reads the plan")
        let roundTripped = try JSONDecoder().decode(AgentPlanRequest.self, from: try JSONEncoder().encode(reading))
        XCTAssertEqual(roundTripped.sessionID, "s1")
        XCTAssertNil(roundTripped.action)
        for action in AgentPlanAction.allCases {
            let request = AgentPlanRequest(sessionID: "s1", action: action)
            let decoded = try JSONDecoder().decode(AgentPlanRequest.self, from: try JSONEncoder().encode(request))
            XCTAssertEqual(decoded.action, action, "\(action.rawValue) survives the wire")
        }
        let empty = AgentPlanResponse(plan: nil)
        XCTAssertNil(try JSONDecoder().decode(AgentPlanResponse.self, from: try JSONEncoder().encode(empty)).plan,
                     "a session with no plan answers none")
    }

    func testAViolationCarriesWhatToTellTheModel() throws {
        let violation = AgentPlanViolation(message: "Step \"one\" is done already")
        let read = try JSONDecoder().decode(AgentPlanViolation.self, from: try JSONEncoder().encode(violation))
        XCTAssertEqual(read.message, "Step \"one\" is done already")
        XCTAssertEqual(read, violation)
    }
}
