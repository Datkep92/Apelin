@testable import ApelinAgent
import enum ApelinProtocol.AgentPlanAction
import enum ApelinProtocol.AgentPlanStepStatus
import enum ApelinProtocol.AgentToolName
import struct ApelinProtocol.AgentPlan
import struct ApelinProtocol.AgentPlanStep
import struct ApelinProtocol.AgentPlanViolation
import Foundation
import Testing

/// The session's plan: written whole, kept where a conversation opened again
/// reads the same steps, `done` only on evidence naming a tool that really
/// ran here, and the user's pause holding against the model.
@Suite("The session's plan")
struct SessionPlanTests {
    /// What the session wrote down, in the order it was written.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [AgentSessionEvent] = []
        private var saved: [AgentPlan?] = []

        func record(_ event: AgentSessionEvent) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func save(_ plan: AgentPlan?) {
            lock.lock()
            saved.append(plan)
            lock.unlock()
        }

        var all: [AgentSessionEvent] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }

        var plans: [AgentPlan?] {
            lock.lock()
            defer { lock.unlock() }
            return saved
        }
    }

    private func makePlan() -> (plan: SessionPlan, log: Log) {
        let log = Log()
        let plan = SessionPlan(record: { log.record($0) }, save: { log.save($0) })
        return (plan, log)
    }

    /// The refusal a write came back with, or nil when it was taken.
    private func refusal(_ work: () async throws -> AgentPlan) async -> AgentPlanViolation? {
        do {
            _ = try await work()
            Issue.record("the plan should have been refused")
            return nil
        } catch let violation as AgentPlanViolation {
            return violation
        } catch {
            Issue.record("refused with \(error), not a plan violation")
            return nil
        }
    }

    private func step(_ id: String, _ title: String) -> AgentPlanStep {
        AgentPlanStep(id: id, title: title)
    }

    @Test
    func `a plan is written whole, kept in the log, and read back`() async throws {
        let (plan, log) = makePlan()
        let written = try await plan.update([step("one", "Read ToolRunner"), step("two", "Change it")])
        #expect(written.revision == 1)
        #expect(written.state == .active)
        #expect(written.steps.map(\.id) == ["one", "two"])
        #expect(log.all == [.plan(written)])
        #expect(log.plans == [written], "the plan outlives the turn that wrote it")

        let current = await plan.current()
        #expect(current == written)
        let line = await plan.stateLine()
        #expect(line == written.promptBlock, "a turn after this one reads the steps")

        // A plan is written whole, never a step at a time: a step left out is
        // left out of the plan.
        let second = try await plan.update([step("two", "Change it")])
        #expect(second.revision == 2)
        #expect(second.steps.map(\.id) == ["two"])
        let lineAgain = await plan.stateLine()
        #expect(lineAgain == second.promptBlock)
        #expect(log.all == [.plan(written), .plan(second)])
    }

    @Test
    func `a step is done only on evidence naming a tool that ran here`() async throws {
        let (plan, _) = makePlan()
        let claimed = AgentPlanStep(
            id: "read",
            title: "Read ToolRunner",
            status: .done,
            evidence: "file_read: showed ToolRunner.swift, 240 lines",
        )
        let nothingRan = await refusal { try await plan.update([claimed]) }
        #expect(nothingRan != nil, "a tool that never ran here is not evidence")
        #expect(nothingRan?.message.contains("nothing yet") == true, "and the refusal says nothing ran here")

        await plan.noteRan(.fileRead)
        let written = try await plan.update([claimed])
        #expect(written.steps[0].status == .done)
        #expect(written.steps[0].evidence == "file_read: showed ToolRunner.swift, 240 lines")

        // The tools that did run are what the refusal offers, never a guess.
        let (other, _) = makePlan()
        await other.noteRan(.shellRun)
        let wrongTool = await refusal {
            try await other.update([
                AgentPlanStep(id: "read", title: "Read", status: .done, evidence: "file_read: a file"),
            ])
        }
        #expect(wrongTool?.message.contains("shell_run") == true, "the refusal names what did run")
        #expect(wrongTool?.message.contains("file_read") == false, "and not what did not")
    }

    @Test
    func `the plan's own tool is not evidence of anything done`() async throws {
        let (plan, _) = makePlan()
        await plan.noteRan(.planUpdate)
        let claimed = await refusal {
            try await plan.update([
                AgentPlanStep(id: "read", title: "Read", status: .done, evidence: "plan_update: wrote the plan"),
            ])
        }
        #expect(claimed != nil)
    }

    @Test
    func `a step that ended stays ended`() async throws {
        let (plan, _) = makePlan()
        await plan.noteRan(.fileRead)
        let done = AgentPlanStep(id: "read", title: "Read it", status: .done, evidence: "file_read: 240 lines")
        let first = try await plan.update([done, step("edit", "Change it")])

        let back = await refusal { try await plan.update([step("read", "Read it"), step("edit", "Change it")]) }
        #expect(back != nil, "a later plan_update never moves a step back")
        #expect(back?.message.contains("done") == true)

        let again = try await plan.update([done, step("edit", "Change it")])
        #expect(again.revision == first.revision + 1, "the same plan written again is a new revision")
        #expect(again.steps[0].status == .done)
    }

    @Test
    func `a step that ended with nothing to back it is refused`() async throws {
        let (plan, _) = makePlan()
        let failed = await refusal {
            try await plan.update([AgentPlanStep(id: "read", title: "Read", status: .failed)])
        }
        #expect(failed?.message.contains("evidence") == true)

        let blank = await refusal {
            try await plan.update([AgentPlanStep(id: "read", title: "Read", status: .skipped, evidence: "   ")])
        }
        #expect(blank != nil, "whitespace is not a reason")

        let going = try await plan.update([AgentPlanStep(id: "read", title: "Read", status: .running)])
        #expect(going.steps[0].evidence == nil, "a step being done now needs no evidence yet")
    }

    @Test
    func `the user's pause holds against the model`() async throws {
        let (plan, log) = makePlan()
        let written = try await plan.update([step("read", "Read ToolRunner")])

        let paused = await plan.apply(.pause)
        #expect(paused?.state == .paused)
        #expect(paused?.revision == written.revision + 1)
        let pausedLine = await plan.stateLine()
        #expect(pausedLine?.contains("The user paused this plan") == true)

        let raced = await refusal {
            try await plan.update([AgentPlanStep(id: "read", title: "Read ToolRunner", status: .running)])
        }
        #expect(raced?.message.contains("paused") == true, "the model is told why nothing moved")

        let stillPaused = await plan.apply(.pause)
        #expect(stillPaused?.revision == paused?.revision, "pausing a paused plan writes nothing")
        #expect(log.all.count == 2)

        let resumed = await plan.apply(.resume)
        #expect(resumed?.state == .active)
        let going = try await plan.update([AgentPlanStep(id: "read", title: "Read ToolRunner", status: .running)])
        #expect(going.state == .active)
        #expect(going.steps[0].status == .running)
    }

    @Test
    func `cancelling skips what has not ended and keeps what did`() async throws {
        let (plan, log) = makePlan()
        await plan.noteRan(.fileRead)
        let written = try await plan.update([
            AgentPlanStep(id: "read", title: "Read it", status: .done, evidence: "file_read: 240 lines"),
            AgentPlanStep(id: "edit", title: "Change it", status: .running),
            step("build", "Build it"),
        ])
        let cancelled = await plan.apply(.cancel)
        #expect(cancelled?.state == .cancelled)
        #expect(cancelled?.revision == written.revision + 1)
        #expect(cancelled?.steps.map(\.status) == [.done, .skipped, .skipped])
        #expect(cancelled?.steps[0].evidence == "file_read: 240 lines", "what was done stays what was done")
        #expect(cancelled?.steps[1].evidence == "The user cancelled the plan.")
        #expect(cancelled?.isFinished == true)
        #expect(log.all.first == .plan(written))
        #expect(log.all.count == 2, "the plan as it now stands is written")
        if let cancelled {
            #expect(log.all.last == .plan(cancelled))
        }
    }

    @Test
    func `clearing forgets the plan, and nothing answers afterwards`() async throws {
        let (plan, log) = makePlan()
        _ = try await plan.update([step("read", "Read ToolRunner")])

        let cleared = await plan.apply(.clear)
        #expect(cleared == nil)
        let current = await plan.current()
        #expect(current == nil)
        let line = await plan.stateLine()
        #expect(line == nil, "a cleared plan is not in the session's state")
        #expect(log.all.last == .planCleared)
        #expect(log.plans.count == 2)
        #expect(log.plans.last! == nil, "a cleared plan is saved as none")

        let nothing = await plan.apply(.pause)
        #expect(nothing == nil, "there is no plan left to pause")
        #expect(log.all.count == 2, "and nothing more is written")

        // The model may write a new plan: it starts at the first revision again.
        let fresh = try await plan.update([step("again", "Start again")])
        #expect(fresh.revision == 1)
        #expect(fresh.steps.map(\.id) == ["again"])
    }

    @Test
    func `a session that never had a plan answers none`() async throws {
        let (plan, log) = makePlan()
        let current = await plan.current()
        #expect(current == nil)
        let line = await plan.stateLine()
        #expect(line == nil)
        let resumed = await plan.apply(.resume)
        #expect(resumed == nil)
        #expect(log.all.isEmpty, "and writes nothing at all")
    }
}
