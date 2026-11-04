import ApelinCore
import ApelinProtocol
import Foundation

/// The plan a conversation is on: how it is read out of the session's
/// events, and the words the plan bar draws for it. Kept apart from the
/// reader, so a plan can be read from events alone (`Tests/ChatPlan`).
enum ChatPlan {
    /// The plan the events end on. The last `plan` event with a payload is
    /// it; a later one without (`planCleared`) means the conversation has
    /// none; nil means it never had one.
    static func in(_ events: [TaskEvent]) -> AgentPlan? {
        for event in events.reversed() where isPlanEvent(event) {
            return (try? event.payload?.decode(AgentPlan.self)) ?? nil
        }
        return nil
    }

    /// Whether `event` carries the plan: what a reader follows to know when
    /// to draw the bar again.
    static func isPlanEvent(_ event: TaskEvent) -> Bool {
        event.kind == AgentPlan.eventKind
    }

    /// The step's mark, as the model writes a plan in its own messages.
    /// `AgentPlanStepStatus.mark` is the one table of them.
    static func glyph(_ status: AgentPlanStepStatus) -> String {
        status.mark
    }

    /// What a step's status is called, for a reader.
    static func name(_ status: AgentPlanStepStatus) -> String {
        switch status {
        case .pending: String(localized: "Not started")
        case .running: String(localized: "In progress")
        case .done: String(localized: "Done")
        case .failed: String(localized: "Failed")
        case .skipped: String(localized: "Skipped")
        }
    }

    /// The line the closed bar draws, and the value the reader hears on it:
    /// how far the plan has got and what it is doing now. The model writes
    /// the step titles; the app writes the rest.
    static func line(for plan: AgentPlan) -> String {
        // The fraction is one value, so the key has a single argument: its
        // specifier is written by the compiler alone, with no position to
        // guess at.
        let fraction = "\(plan.doneCount)/\(plan.steps.count)"
        let count = String(localized: "\(fraction) steps done")
        switch plan.state {
        case .cancelled:
            return "\(count) · \(String(localized: "Cancelled"))"
        case .paused:
            return "\(count) · \(String(localized: "Paused"))"
        case .active:
            guard let current = plan.toldStep else {
                return "\(count) · \(String(localized: "Finished"))"
            }
            switch current.status {
            case .running:
                return "\(count) · \(current.title)"
            case .failed:
                return "\(count) · \(String(localized: "Failed")): \(current.title)"
            default:
                return "\(count) · \(String(localized: "Next")): \(current.title)"
            }
        }
    }

    /// Where a step stands and what the session recorded for it: the value a
    /// step's row is read with, and what opening it in full repeats.
    static func detail(of step: AgentPlanStep) -> String {
        var lines = [name(step.status)]
        if let evidence = step.evidence, !evidence.isEmpty {
            lines.append(evidence)
        }
        return lines.joined(separator: " — ")
    }
}
