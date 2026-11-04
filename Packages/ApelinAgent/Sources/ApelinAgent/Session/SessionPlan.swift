import ApelinProtocol
import Foundation

/// The session's plan, and the only place one is written: the steps of the
/// work the model is doing, where each one stands, and what it may write
/// next. The model reaches it through `plan_update`; the user through the
/// conversation's plan bar (`AgentPlanAction`). Both leave a `plan` event in
/// the session's log, so the plan is not the model's memory: a compaction, a
/// model switch, a restart of Apelin or a conversation opened again reads
/// the same steps back.
///
/// Three rules make it worth resuming instead of a note the model keeps to
/// itself:
///
/// - A plan is written whole, never a step at a time, and a step that ended
///   stays ended: a new plan replaces the old one but cannot revive what was
///   done, failed or skipped.
/// - A step is only `done` with evidence naming a tool that really ran in
///   this session (`noteRan`, called where a tool finished without an error)
///   and what it answered. A step the model merely believes it finished is
///   refused, with the reason to tell it.
/// - The user's pause holds: a `plan_update` arriving while the plan is
///   paused is refused, so the model stops taking steps instead of racing
///   the hand that stopped it.
///
/// Evidence kept this way is short on purpose: the tool's name and one line
/// of what it said. The full output is in the session's own tool events, a
/// tap away in the transcript, and a plan that pasted its output would cost
/// more context than it saves.
public actor SessionPlan {
    private var plan: AgentPlan?
    /// The tools that finished in this session without an error: what a
    /// `done` step's evidence has to name.
    private var ranTools: Set<String> = []
    private let record: @Sendable (AgentSessionEvent) async -> Void
    /// Where the plan is kept so a restart reads the same steps back; the
    /// session writes it beside its transcript.
    private let save: @Sendable (AgentPlan?) async -> Void

    public init(
        plan: AgentPlan? = nil,
        record: @escaping @Sendable (AgentSessionEvent) async -> Void,
        save: @escaping @Sendable (AgentPlan?) async -> Void = { _ in },
    ) {
        self.plan = plan
        self.record = record
        self.save = save
    }

    public func current() -> AgentPlan? {
        plan
    }

    /// What `<system-state>` carries, or nil when there is no plan: the steps
    /// and where they stand, so the turn after a compaction, a model switch
    /// or a reopened conversation goes on from the right step.
    public func stateLine() -> String? {
        plan?.promptBlock
    }

    /// A tool finished, without an error, in this session. Called from the
    /// one place every tool goes through, so it counts what ran and not what
    /// was asked for.
    public func noteRan(_ tool: AgentToolName) {
        // The plan's own tool is not evidence of anything done.
        guard tool != .planUpdate else { return }
        ranTools.insert(tool.rawValue)
    }

    /// Writes the whole plan, refusing one that breaks a rule or claims an
    /// ended step it cannot back. The violation's `message` is what the model
    /// is told.
    public func update(_ steps: [AgentPlanStep]) async throws -> AgentPlan {
        let steps = try AgentPlanRules.validate(steps)
        let previous = plan
        if previous?.state == .paused {
            throw AgentPlanViolation(message: "The user paused this plan in the plan bar: do not change it and take no step of it. Say where the work stopped and what would come next, and wait for the user to resume it.")
        }
        let earlier = Dictionary((previous?.steps ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for step in steps {
            if let old = earlier[step.id] {
                if let refusal = AgentPlanRules.refusesChange(from: old.status, to: step.status) {
                    throw AgentPlanViolation(message: refusal)
                }
                if step.status == .done, old.status != .done, !namesARanTool(step.evidence) {
                    throw AgentPlanViolation(message: "Step \"\(step.id)\" is done only with evidence naming a tool that really ran here and what it answered, such as \"file_read: showed ToolRunner.swift, 240 lines\". This session ran: \(ranLine()).")
                }
            } else if step.status == .done, !namesARanTool(step.evidence) {
                throw AgentPlanViolation(message: "Step \"\(step.id)\" is done only with evidence naming a tool that really ran here and what it answered. This session ran: \(ranLine()).")
            }
            if step.status.isSettled, (step.evidence ?? "").isEmpty {
                throw AgentPlanViolation(message: "Step \"\(step.id)\" is \(step.status.rawValue) with no evidence: say in evidence what says so — for done, the tool that ran and what it answered; for failed or skipped, why.")
            }
        }
        let next = AgentPlan(
            steps: steps,
            state: .active,
            revision: (previous?.revision ?? 0) + 1,
            updatedAt: Date(),
        )
        plan = next
        await save(next)
        await record(.plan(next))
        return next
    }

    /// What the user asked for in the bar. Answers the plan as it stands
    /// afterwards: nil once cleared, and nil for a session that never had
    /// one.
    @discardableResult
    public func apply(_ action: AgentPlanAction) async -> AgentPlan? {
        guard let current = plan else { return nil }
        if action == .clear {
            plan = nil
            await save(nil)
            await record(.planCleared)
            return nil
        }
        var next = current
        switch action {
        case .pause:
            next.state = .paused
        case .resume:
            next.state = .active
        case .cancel:
            next.state = .cancelled
            next.steps = current.steps.map { step in
                guard !step.status.isSettled else { return step }
                return AgentPlanStep(
                    id: step.id,
                    title: step.title,
                    status: .skipped,
                    evidence: step.evidence ?? "The user cancelled the plan.",
                )
            }
        case .clear:
            return nil
        }
        guard next != current else { return current }
        next.revision = current.revision + 1
        next.updatedAt = Date()
        plan = next
        await save(next)
        await record(.plan(next))
        return next
    }

    /// Whether `evidence` names a tool that finished here without an error.
    private func namesARanTool(_ evidence: String?) -> Bool {
        guard let evidence else { return false }
        let known = Set(AgentToolName.allCases.map(\.rawValue))
        return AgentPlanRules.tools(in: evidence, known: known).contains { ranTools.contains($0) }
    }

    /// The tools that ran, for the refusal to name them: what the model can
    /// cite honestly instead of guessing.
    private func ranLine() -> String {
        let names = ranTools.sorted()
        guard !names.isEmpty else { return "nothing yet — run the step's own tool first, then mark it done" }
        let shown = names.prefix(12).joined(separator: ", ")
        return names.count > 12 ? "\(shown), and \(names.count - 12) more" : shown
    }
}