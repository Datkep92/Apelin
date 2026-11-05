@testable import ApelinAgent
import enum ApelinProtocol.AgentPlanAction
import enum ApelinProtocol.AgentPlanState
import enum ApelinProtocol.AgentPlanStepStatus
import struct ApelinProtocol.AgentPlan
import struct ApelinProtocol.AgentPlanStep
import Foundation
import Testing

/// The Resume button in the plan bar turns a resumed plan into a real run only
/// when it has work left to do and nothing else is running.
@Suite("Whether resuming a plan starts a run")
struct PlanResumeRunTests {
    private static let activeWithPending = AgentPlan(
        steps: [AgentPlanStep(id: "one", title: "Do it", status: .pending)],
        state: .active,
        revision: 1,
    )
    private static let activeFinished = AgentPlan(
        steps: [AgentPlanStep(id: "one", title: "Done", status: .done, evidence: "file_read: wrote it")],
        state: .active,
        revision: 1,
    )
    private static let paused = AgentPlan(
        steps: [AgentPlanStep(id: "one", title: "Do it", status: .pending)],
        state: .paused,
        revision: 1,
    )

    @Test
    func `only a resumed active plan with pending steps and no running task starts a run`() {
        #expect(
            AgentSession.shouldStartResumeRun(
                action: .resume,
                applied: Self.activeWithPending,
                runTaskActive: false,
            ) == true,
        )
    }

    @Test(arguments: AgentPlanAction.allCases.filter { $0 != .resume })
    func `other bar actions never start a run`(action: AgentPlanAction) {
        #expect(
            AgentSession.shouldStartResumeRun(
                action: action,
                applied: Self.activeWithPending,
                runTaskActive: false,
            ) == false,
        )
    }

    @Test
    func `a missing, paused, or cancelled applied plan never starts a run`() {
        #expect(AgentSession.shouldStartResumeRun(action: .resume, applied: nil, runTaskActive: false) == false)
        #expect(AgentSession.shouldStartResumeRun(action: .resume, applied: Self.paused, runTaskActive: false) == false)

        let cancelled = AgentPlan(
            steps: [AgentPlanStep(id: "one", title: "Do it", status: .pending)],
            state: .cancelled,
            revision: 1,
        )
        #expect(AgentSession.shouldStartResumeRun(action: .resume, applied: cancelled, runTaskActive: false) == false)
    }

    @Test
    func `a finished active plan does not start a synthetic run`() {
        #expect(AgentSession.shouldStartResumeRun(action: .resume, applied: Self.activeFinished, runTaskActive: false) == false)
    }

    @Test
    func `an already running task is not prompted again`() {
        #expect(AgentSession.shouldStartResumeRun(action: .resume, applied: Self.activeWithPending, runTaskActive: true) == false)
    }
}
