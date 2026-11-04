import ApelinCore
import ApelinProtocol
import Foundation

// The plan a conversation is on, read out of the session's events alone, and
// the words the plan bar draws and reads for it: the line at its top and the
// value each step's row is read with.

func planEvent(_ seq: UInt64, _ plan: AgentPlan) -> TaskEvent {
    TaskEvent(
        seq: EventSeq(seq),
        kind: AgentPlan.eventKind,
        time: Date(timeIntervalSince1970: Double(seq)),
        payload: (try? JSONValue(encoding: plan)) ?? .null,
    )
}

func otherEvent(_ seq: UInt64, _ kind: String) -> TaskEvent {
    TaskEvent(
        seq: EventSeq(seq),
        kind: kind,
        time: Date(timeIntervalSince1970: Double(seq)),
        payload: .object([:]),
    )
}

/// The plan is gone: the same kind with a null payload.
func clearedEvent(_ seq: UInt64) -> TaskEvent {
    TaskEvent(seq: EventSeq(seq), kind: AgentPlan.eventKind, time: Date(timeIntervalSince1970: Double(seq)), payload: .null)
}

/// `String(localized:)` as the bar writes it, so the check compares the call
/// the app makes with the call the harness makes.
func stepsDone(_ done: Int, _ total: Int) -> String {
    let fraction = "\(done)/\(total)"
    return String(localized: "\(fraction) steps done")
}

let reading = AgentPlan(steps: [
    AgentPlanStep(id: "one", title: "Read ToolRunner", status: .done, evidence: "file_read: 240 lines"),
    AgentPlanStep(id: "two", title: "Change it", status: .running),
    AgentPlanStep(id: "three", title: "Build it"),
], revision: 3, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

// The plan the events end on: the last one written, gone after a cleared
// one, and none at all for a conversation that never had one.
precondition(ChatPlan.latest(in: []) == nil, "a conversation that never had a plan has none")
precondition(ChatPlan.latest(in: [otherEvent(1, "message")]) == nil)
precondition(ChatPlan.latest(in: [planEvent(2, reading)]) == reading)
precondition(
    ChatPlan.latest(in: [planEvent(2, reading), otherEvent(3, "message")]) == reading,
    "an event that is not a plan leaves the plan standing",
)
precondition(ChatPlan.latest(in: [planEvent(2, reading), clearedEvent(3)]) == nil, "a cleared plan is gone")
let older = AgentPlan(steps: [AgentPlanStep(id: "one", title: "Read it")], revision: 2)
precondition(ChatPlan.latest(in: [planEvent(1, reading), planEvent(2, older)]) == older, "the last plan written is the one")
precondition(
    ChatPlan.latest(in: [clearedEvent(1), planEvent(2, reading)]) == reading,
    "a new plan written after a cleared one is read",
)
precondition(ChatPlan.isPlanEvent(planEvent(1, reading)))
precondition(ChatPlan.isPlanEvent(clearedEvent(1)), "a cleared plan is still the plan's own event")
precondition(!ChatPlan.isPlanEvent(otherEvent(1, "message")))

// Every status has its own mark and its own name, and a status is called one
// thing wherever it is read.
precondition(AgentPlanStepStatus.allCases.map(ChatPlan.glyph) == ["[ ]", "[>]", "[x]", "[!]", "[-]"])
let names = AgentPlanStepStatus.allCases.map(ChatPlan.name)
precondition(names == [
    String(localized: "Not started"), String(localized: "In progress"),
    String(localized: "Done"), String(localized: "Failed"), String(localized: "Skipped"),
])
precondition(Set(names).count == 5, "no two statuses read the same")

// The line at the top of the bar: how far the plan has got, then what it is
// doing now.
precondition(ChatPlan.line(for: reading) == "\(stepsDone(1, 3)) · Change it", "the step being done is named")
precondition(
    ChatPlan.line(for: AgentPlan(steps: reading.steps, state: .paused, revision: 4))
        == "\(stepsDone(1, 3)) · \(String(localized: "Paused"))",
)
precondition(
    ChatPlan.line(for: AgentPlan(steps: reading.steps, state: .cancelled, revision: 5))
        == "\(stepsDone(1, 3)) · \(String(localized: "Cancelled"))",
)
let next = AgentPlan(steps: [
    AgentPlanStep(id: "one", title: "Read it", status: .done, evidence: "file_read: 240 lines"),
    AgentPlanStep(id: "two", title: "Change it"),
], revision: 6)
precondition(ChatPlan.line(for: next) == "\(stepsDone(1, 2)) · \(String(localized: "Next")): Change it")
let allDone = AgentPlan(steps: [
    AgentPlanStep(id: "one", title: "Read it", status: .done, evidence: "file_read: 240 lines"),
], revision: 7)
precondition(ChatPlan.line(for: allDone) == "\(stepsDone(1, 1)) · \(String(localized: "Finished"))")

// A step that did not work is named, not hidden behind Finished.
let failed = AgentPlan(steps: [
    AgentPlanStep(id: "one", title: "Build it", status: .failed, evidence: "the build stopped at a write error"),
], revision: 8)
precondition(failed.isFinished)
precondition(failed.toldStep?.id == "one", "a plan whose step failed still has something to say")
precondition(ChatPlan.line(for: failed) == "\(stepsDone(0, 1)) · \(String(localized: "Failed")): Build it")
precondition(
    ChatPlan.line(for: AgentPlan(steps: [
        AgentPlanStep(id: "one", title: "Read it", status: .done, evidence: "file_read: 240 lines"),
        AgentPlanStep(id: "two", title: "Build it", status: .failed, evidence: "the build stopped"),
    ], revision: 9)) == "\(stepsDone(1, 2)) · \(String(localized: "Failed")): Build it",
)
// A skipped step is the user's own ending: it is not read out at the top.
precondition(
    ChatPlan.line(for: AgentPlan(steps: [
        AgentPlanStep(id: "one", title: "Read it", status: .done, evidence: "file_read: 240 lines"),
        AgentPlanStep(id: "two", title: "Not needed", status: .skipped, evidence: "the user settled it another way"),
    ], revision: 10)) == "\(stepsDone(1, 2)) · \(String(localized: "Finished"))",
)

// Where a step stands, and what backed it: the value a row is read with.
precondition(ChatPlan.detail(of: reading.steps[0])
    == String(localized: "Done") + " — file_read: 240 lines")
precondition(ChatPlan.detail(of: reading.steps[1]) == String(localized: "In progress"), "nothing backed it yet")
precondition(ChatPlan.detail(of: AgentPlanStep(id: "x", title: "X", status: .done, evidence: ""))
    == String(localized: "Done"), "empty evidence is no evidence")
