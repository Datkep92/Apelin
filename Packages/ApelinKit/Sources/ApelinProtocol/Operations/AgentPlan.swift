import Foundation

/// A plan the assistant carries out: the steps, in the order it will do
/// them, and where each one stands. It is the assistant's own note to
/// itself and to the user, made through the `plan_update` tool and drawn
/// in the conversation's plan bar. It lives in the session's event log, so
/// a plan outlives the turn that wrote it: a compaction, a model switch, a
/// restart of Apelin or a conversation opened again all reach the same
/// steps, and a step already `done` is not done twice.
public struct AgentPlan: Codable, Sendable, Hashable {
    /// The kind of the session event that carries a plan to the app
    /// (`plan`), whose payload is this type. `planCleared`'s payload is null,
    /// and means the plan is gone.
    public static let eventKind = "plan"

    public var steps: [AgentPlanStep]
    /// Whether the plan is going, stopped by the user, or ended.
    public var state: AgentPlanState
    /// How many times the plan was written; the bar ignores an older one.
    public var revision: Int
    public var updatedAt: Date

    public init(
        steps: [AgentPlanStep],
        state: AgentPlanState = .active,
        revision: Int = 1,
        updatedAt: Date = Date(),
    ) {
        self.steps = steps
        self.state = state
        self.revision = revision
        self.updatedAt = updatedAt
    }

    /// How many steps are done.
    public var doneCount: Int {
        steps.filter { $0.status == .done }.count
    }

    /// How many steps ended, however they ended.
    public var settledCount: Int {
        steps.filter { $0.status.isSettled }.count
    }

    /// The step being done now, else the first one not settled.
    public var currentStep: AgentPlanStep? {
        steps.first { $0.status == .running } ?? steps.first { !$0.status.isSettled }
    }

    /// The step a reader should be told about now: the one being done, else
    /// the first not settled, else the one that did not work. A plan with a
    /// step that failed is not a finished one, so it is named rather than
    /// hidden behind `Finished`.
    public var toldStep: AgentPlanStep? {
        currentStep ?? steps.first { $0.status == .failed }
    }

    /// Every step ended, and at least one of them: nothing is left to do.
    public var isFinished: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status.isSettled }
    }

    /// `2/8 done · Running step title`, the line a reader hears, or
    /// `2/8 done · Paused`, or `Cancelled` for a plan the user ended.
    public var progressLine: String {
        let count = "\(doneCount)/\(steps.count)"
        switch state {
        case .cancelled: return "\(count) · Cancelled"
        case .paused: return "\(count) · Paused"
        case .active:
            guard let step = toldStep else { return "\(count) · Finished" }
            switch step.status {
            case .running: return "\(count) · \(step.title)"
            case .failed: return "\(count) · Failed: \(step.title)"
            default: return "\(count) · Next: \(step.title)"
            }
        }
    }

    /// The plan as the model reads it, into `<system-state>`: every step
    /// with its status, so a turn that follows a compaction, a model switch
    /// or a reopened conversation knows what is already done and goes on
    /// from there instead of doing it again. Bounded by `AgentPlanRules`:
    /// at most twelve steps, each line one step.
    public var promptBlock: String {
        var lines = ["- Plan (\(progressLine)):"]
        for (index, step) in steps.enumerated() {
            var line = "  \(index + 1). [\(step.status.rawValue)] \(step.title)"
            if let evidence = step.evidence, !evidence.isEmpty {
                line += " — \(evidence)"
            }
            lines.append(line)
        }
        if state == .paused {
            lines.append("  The user paused this plan: do not update it, and take no step of it, until the user resumes it.")
        }
        return lines.joined(separator: "\n")
    }
}

/// Where one step of a plan stands.
public enum AgentPlanStepStatus: String, Codable, Sendable, Hashable, CaseIterable {
    /// Not started.
    case pending
    /// Being done now; at most one step of a plan is.
    case running
    /// Done, with the evidence that says so.
    case done
    /// Tried and it did not work.
    case failed
    /// Left out, with a reason in its evidence: not needed, or the user
    /// settled it another way.
    case skipped

    /// Ended one way or another: a later `plan_update` does not move it.
    public var isSettled: Bool {
        switch self {
        case .done, .failed, .skipped: true
        case .pending, .running: false
        }
    }

    /// The three characters this status is drawn with: the plan bar, the
    /// model's answer to `plan_update` and a plan written in a message all
    /// read this one table.
    public var mark: String {
        switch self {
        case .pending: "[ ]"
        case .running: "[>]"
        case .done: "[x]"
        case .failed: "[!]"
        case .skipped: "[-]"
        }
    }
}

/// Whether a plan is going, stopped by the user, or ended.
public enum AgentPlanState: String, Codable, Sendable, Hashable {
    case active
    case paused
    case cancelled
}

public struct AgentPlanStep: Codable, Sendable, Hashable {
    /// The model's own short name for the step, unique in the plan: it
    /// names the step when only its status changes.
    public var id: String
    public var title: String
    public var status: AgentPlanStepStatus
    /// What says so for a step that ended: for `done`, the tool that ran
    /// and its result, which `SessionPlan` checks against the tools this
    /// session really ran; for `skipped` or `failed`, why.
    public var evidence: String?

    public init(
        id: String,
        title: String,
        status: AgentPlanStepStatus = .pending,
        evidence: String? = nil,
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.evidence = evidence
    }
}

/// What the rules allow in a plan, checked before one is written: they hold
/// for the model's `plan_update` and for a plan read back from a log (a
/// file the device's user could edit).
public enum AgentPlanRules {
    /// A plan longer than this is a plan nobody reads: it is refused, and
    /// the model is told to make it shorter.
    public static let maximumSteps = 12
    public static let maximumTitleCharacters = 120
    public static let maximumIDCharacters = 40
    public static let maximumEvidenceCharacters = 400

    /// `steps` with each field trimmed, refused unless every rule holds.
    /// A plan is written whole, never a step at a time: the model sends the
    /// list it wants to stand, so a step left out is left out.
    public static func validate(_ steps: [AgentPlanStep]) throws -> [AgentPlanStep] {
        guard !steps.isEmpty else {
            throw AgentPlanViolation(message: "A plan needs at least one step.")
        }
        guard steps.count <= maximumSteps else {
            throw AgentPlanViolation(message: "A plan holds at most \(maximumSteps) steps (\(steps.count) sent). Send the whole plan again, shorter.")
        }
        var seen: Set<String> = []
        var running = 0
        var normalized: [AgentPlanStep] = []
        for step in steps {
            let id = step.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= maximumIDCharacters, !id.contains(where: \.isNewline) else {
                throw AgentPlanViolation(message: "Every step needs an id of at most \(maximumIDCharacters) characters on one line.")
            }
            guard seen.insert(id).inserted else {
                throw AgentPlanViolation(message: "Two steps share the id \"\(id)\": every step needs its own.")
            }
            guard !title.isEmpty, title.count <= maximumTitleCharacters, !title.contains(where: \.isNewline) else {
                throw AgentPlanViolation(message: "Step \"\(id)\" needs a title of at most \(maximumTitleCharacters) characters on one line.")
            }
            if step.status == .running {
                running += 1
            }
            let evidence = step.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let evidence, evidence.count > maximumEvidenceCharacters {
                throw AgentPlanViolation(message: "Step \"\(id)\" needs evidence of at most \(maximumEvidenceCharacters) characters.")
            }
            normalized.append(AgentPlanStep(
                id: id,
                title: title,
                status: step.status,
                evidence: (evidence?.isEmpty ?? true) ? nil : evidence,
            ))
        }
        guard running <= 1 else {
            throw AgentPlanViolation(message: "Only one step can be running at a time (\(running) sent).")
        }
        return normalized
    }

    /// How the status of a step just sent differs from the one it replaces:
    /// nil when it may not change that way. A step that ended stays ended —
    /// a plan is a record of what was done, not a draft — but its title and
    /// evidence may be corrected, and the user's own actions (pause,
    /// cancel) are not the model's to undo.
    public static func refusesChange(
        from previous: AgentPlanStepStatus,
        to next: AgentPlanStepStatus,
    ) -> String? {
        guard previous.isSettled, next != previous else { return nil }
        return "Step is \(previous.rawValue) already: a step that ended stays \(previous.rawValue), and a later plan_update never moves it back."
    }

    /// The tool names `evidence` names, out of `known`: what a `done` step
    /// may rest on. Read as whole words, so `file_read` in a sentence is
    /// found and `file_reader` is not.
    public static func tools(in evidence: String, known: Set<String>) -> [String] {
        let words = evidence.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
        var found: [String] = []
        for word in words {
            let name = String(word)
            if known.contains(name), !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }
}

/// A plan that breaks a rule, with what to tell the model about it.
public struct AgentPlanViolation: Error, Codable, Sendable, Hashable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

/// What the user asks of a plan from the conversation's plan bar. The app
/// alone calls it; the model changes a plan through `plan_update`.
public enum AgentPlanAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Stop it: the step being done stays as it is, and a `plan_update` is
    /// refused until the user resumes it.
    case pause
    /// Carry on from the step the plan stopped at.
    case resume
    /// End it: what has not ended is `skipped`, and no `plan_update` is
    /// taken afterwards but one that starts a new plan.
    case cancel
    /// Forget it: the bar goes, and the model may write a new plan.
    case clear
}

public struct AgentPlanRequest: OperationRequest {
    public typealias Response = AgentPlanResponse
    public static let operation = AppOperation.agentPlan

    public var sessionID: String
    /// What to do with the plan, or nil to only read it — what a
    /// conversation opened again, or the bar drawing itself, asks for.
    public var action: AgentPlanAction?

    public init(sessionID: String, action: AgentPlanAction? = nil) {
        self.sessionID = sessionID
        self.action = action
    }
}

/// The plan as it stands after the action: nil once cleared, and nil for a
/// session that never had one.
public struct AgentPlanResponse: Codable, Sendable, Hashable {
    public var plan: AgentPlan?

    public init(plan: AgentPlan?) {
        self.plan = plan
    }
}

public extension ApelinService {
    /// Reads the session's plan (no action), or pauses, resumes, cancels or
    /// clears it, and answers the plan as it stands.
    func agentPlan(sessionID: String, action: AgentPlanAction? = nil) async throws -> AgentPlanResponse {
        try await send(AgentPlanRequest(sessionID: sessionID, action: action))
    }
}
