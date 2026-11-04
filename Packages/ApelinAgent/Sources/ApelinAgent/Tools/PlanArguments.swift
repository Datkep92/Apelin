import enum ApelinProtocol.AgentPlanStepStatus
import struct ApelinProtocol.AgentPlan
import struct ApelinProtocol.AgentPlanStep
import Foundation
import KWWKAI

/// `plan_update`'s arguments, read as the plan they describe, and the line
/// the model is answered with. The plan itself is the session's
/// (`SessionPlan`): these are only the two translations at the tool's edge.
enum PlanArguments {
    /// The steps, in the order sent. A step is `pending` when it names no
    /// status, which is how a plan is written before any of it is done.
    static func steps(in arguments: JSONValue) throws -> [AgentPlanStep] {
        guard case let .object(fields) = arguments, case let .array(items)? = fields["steps"] else {
            throw ToolArgumentError("plan_update needs steps: the whole plan, an array of steps, each with id, title and status.")
        }
        return try items.map { item in
            guard case let .object(fields) = item else {
                throw ToolArgumentError("Every step of the plan is an object with an id, a title and a status.")
            }
            guard let id = string(fields["id"]), !id.isEmpty else {
                throw ToolArgumentError("Every step of the plan needs an id.")
            }
            guard let title = string(fields["title"]), !title.isEmpty else {
                throw ToolArgumentError("Step \"\(id)\" needs a title saying what it does.")
            }
            let raw = string(fields["status"]) ?? AgentPlanStepStatus.pending.rawValue
            guard let status = AgentPlanStepStatus(rawValue: raw) else {
                throw ToolArgumentError("Step \"\(id)\" has status \"\(raw)\": use one of \(AgentPlanStepStatus.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return AgentPlanStep(id: id, title: title, status: status, evidence: string(fields["evidence"]))
        }
    }

    /// What the model reads back: the plan as it now stands, one line a
    /// step, so a wrong status in a long list is visible where it was made.
    static func answer(_ plan: AgentPlan) -> String {
        var lines = ["Plan written: \(plan.progressLine)"]
        for (index, step) in plan.steps.enumerated() {
            var line = "\(step.status.mark) \(index + 1). \(step.title) [\(step.id)]"
            if let evidence = step.evidence {
                line += " — \(evidence)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private static func string(_ value: JSONValue?) -> String? {
        guard case let .string(text)? = value else { return nil }
        return text
    }
}