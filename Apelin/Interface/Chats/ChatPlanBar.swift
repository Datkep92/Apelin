import ApelinProtocol
import SnapKit
import UIKit

/// The plan bar: the plan a conversation is on, above the composer. Closed
/// it is one line — how far the plan has got and what it is doing now — and
/// opened it is the plan's steps, each with the status the session recorded
/// for it, and what the user can do to the plan: pause it, resume it, end
/// it, or clear it away.
///
/// It draws and it asks; it decides nothing. What the user tapped goes to
/// `onAction`, which `ChatController` passes on to `ChatRuntime` — the plan
/// itself lives in the session, so the bar and the model never disagree
/// about it.
final class ChatPlanBar: UIView {
    /// What the user asked of the plan: `.pause`, `.resume`, `.cancel` or
    /// `.clear`.
    var onAction: ((AgentPlanAction) -> Void)?
    /// A step the user wants in full: the step and the number it is shown as.
    var onStepDetail: ((AgentPlanStep, Int) -> Void)?
    /// The room it now needs changed: opening or closing the steps is the
    /// bar's own doing, and the height it is given is its host's, which
    /// moves the conversation list with it.
    var onHeightChange: (() -> Void)?

    /// The plan drawn, nil while the conversation has none.
    private(set) var plan: AgentPlan?
    /// Step buttons currently shown, so a refresh can relabel them in place.
    private var stepButtons: [UIButton] = []
    /// Whether the reader opened the steps.
    private(set) var isExpanded = false

    /// Steps given room at once. A plan with more of them scrolls, so a
    /// twelve-step plan does not swallow the conversation.
    static let visibleSteps = 5
    static let headerHeight: CGFloat = 44
    static let stepHeight: CGFloat = 28
    static let actionHeight: CGFloat = 48

    private let content = UIStackView()
    private let header = UIButton(type: .system)
    private let scroll = UIScrollView()
    private let steps = UIStackView()
    private let more = UILabel()
    private let actions = UIStackView()
    private let pauseResume = UIButton(type: .system)
    private let endPlan = UIButton(type: .system)
    private let clearPlan = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        clipsToBounds = true

        let separator = UIView()
        separator.backgroundColor = .separator
        addSubview(separator)
        separator.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview()
            make.height.equalTo(1 / max(traitCollection.displayScale, 1))
        }

        content.axis = .vertical
        content.spacing = 0
        addSubview(content)
        content.snp.makeConstraints { make in
            make.top.equalTo(separator.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        header.contentHorizontalAlignment = .leading
        header.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        header.titleLabel?.numberOfLines = 1
        header.titleLabel?.lineBreakMode = .byTruncatingTail
        header.tintColor = .label
        header.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        header.snp.makeConstraints { make in
            make.height.equalTo(Self.headerHeight)
        }

        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(steps)
        steps.axis = .vertical
        steps.spacing = 0
        steps.snp.makeConstraints { make in
            make.top.bottom.equalTo(scroll.contentLayoutGuide)
            make.leading.trailing.equalTo(scroll.frameLayoutGuide)
        }

        more.font = .preferredFont(forTextStyle: .footnote)
        more.textColor = .tertiaryLabel
        more.numberOfLines = 1
        more.isAccessibilityElement = true
        // Its row height is fixed here, not in `rebuild`: the label outlives
        // every rebuild, and a constraint added again each time would pile
        // up on the same view.
        more.snp.makeConstraints { make in
            make.height.equalTo(Self.stepHeight)
        }

        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8
        for (button, title, action) in [
            (endPlan, String(localized: "End plan"), AgentPlanAction.cancel),
            (clearPlan, String(localized: "Clear plan"), AgentPlanAction.clear),
        ] {
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
        // One button for the two of them: which of the two it is depends on
        // how the plan stands when it is tapped, so its name can never be
        // stale against the state it describes.
        pauseResume.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAction?(self.plan?.state == .paused ? .resume : .pause)
        }, for: .touchUpInside)
        for button in [pauseResume, endPlan, clearPlan] {
            actions.addArrangedSubview(button)
        }
        actions.snp.makeConstraints { make in
            make.height.equalTo(Self.actionHeight)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// The room it asks for: the hairline of its top edge, the line alone
    /// while it is closed, and the steps with their buttons while it is
    /// open. Nothing at all when the conversation has no plan.
    var preferredHeight: CGFloat {
        guard let plan else { return 0 }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        guard isExpanded else { return hairline + Self.headerHeight }
        let shown = min(plan.steps.count, Self.visibleSteps)
        let beyond = plan.steps.count > shown ? Self.stepHeight : 0
        return hairline + Self.headerHeight + CGFloat(shown) * Self.stepHeight + beyond + Self.actionHeight
    }

    /// Draws `plan`, keeping the bar as open or as closed as the reader left
    /// it, and taking it away when there is none. Drawing the plan it is
    /// already drawing changes nothing: a refresh comes with every batch of
    /// a turn, and rebuilding on each of them would take the steps away
    /// from under a reader.
    func show(_ newPlan: AgentPlan?) {
        guard newPlan != self.plan else { return }
        guard let newPlan else {
            self.plan = nil
            isExpanded = false
            clear()
            return
        }
        // Keep the steps under the reader when only their status changes:
        // the skeleton (count and titles) is what rebuilding exists for.
        if self.plan != nil,
           self.plan!.steps.count == newPlan.steps.count,
           zip(self.plan!.steps, newPlan.steps).allSatisfy({ $0.id == $1.id && $0.title == $1.title }) {
            self.plan = newPlan
            updateHeader(newPlan)
            updateStepButtons(newPlan)
            updateActions(newPlan)
            return
        }
        self.plan = newPlan
        rebuild(newPlan)
    }

    private func updateHeader(_ plan: AgentPlan) {
        header.setTitle(ChatPlan.line(for: plan), for: .normal)
        header.accessibilityValue = ChatPlan.line(for: plan)
    }

    private func updateStepButtons(_ plan: AgentPlan) {
        guard isExpanded else { return }
        for (button, step) in zip(stepButtons, plan.steps) {
            button.setTitle("\(ChatPlan.glyph(step.status)) \(button.tag + 1). \(step.title)", for: .normal)
            button.accessibilityValue = ChatPlan.detail(of: step)
        }
    }

    private func updateActions(_ plan: AgentPlan) {
        guard isExpanded else { return }
        pauseResume.setTitle(
            plan.state == .paused ? String(localized: "Resume") : String(localized: "Pause"),
            for: .normal,
        )
        pauseResume.isEnabled = plan.state != .cancelled
        endPlan.isEnabled = plan.state != .cancelled
    }

    private func toggle() {
        guard let plan else { return }
        isExpanded.toggle()
        rebuild(plan)
        onHeightChange?()
    }

    private func rebuild(_ plan: AgentPlan) {
        clear()
        stepButtons.removeAll()
        header.setTitle(ChatPlan.line(for: plan), for: .normal)
        header.setImage(
            UIImage(systemName: isExpanded ? "chevron.down" : "chevron.up"),
            for: .normal,
        )
        // The line already says how far the plan has got, so it is the
        // value; the name it is read under says what the line is.
        header.accessibilityLabel = String(localized: "Plan")
        header.accessibilityValue = ChatPlan.line(for: plan)
        header.accessibilityHint = isExpanded
            ? String(localized: "Double tap to hide the steps")
            : String(localized: "Double tap to show the steps")
        content.addArrangedSubview(header)
        guard isExpanded else { return }

        for (index, step) in plan.steps.enumerated() {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.setTitle("\(ChatPlan.glyph(step.status)) \(index + 1). \(step.title)", for: .normal)
            button.accessibilityLabel = "\(index + 1). \(step.title)"
            button.accessibilityValue = ChatPlan.detail(of: step)
            button.accessibilityHint = String(localized: "Double tap for the whole step")
            button.tag = index
            button.addAction(UIAction { [weak self] _ in self?.detail(index) }, for: .touchUpInside)
            button.snp.makeConstraints { make in
                make.height.equalTo(Self.stepHeight)
            }
            stepButtons.append(button)
            steps.addArrangedSubview(button)
        }
        content.addArrangedSubview(scroll)
        let shown = min(plan.steps.count, Self.visibleSteps)
        scroll.snp.remakeConstraints { make in
            make.height.equalTo(CGFloat(shown) * Self.stepHeight)
        }

        if plan.steps.count > shown {
            more.text = String(localized: "Scroll for the other steps")
            more.accessibilityLabel = String(localized: "More steps")
            content.addArrangedSubview(more)
        }

        // A paused plan is the one the user can send on again; an ended one
        // has nothing left to pause, and only clearing is left to it.
        pauseResume.setTitle(
            plan.state == .paused ? String(localized: "Resume") : String(localized: "Pause"),
            for: .normal,
        )
        pauseResume.isEnabled = plan.state != .cancelled
        endPlan.isEnabled = plan.state != .cancelled
        content.addArrangedSubview(actions)
    }

    /// Where a step stands and what the session recorded for it: the value
    /// the row is read with, and what opening it in full repeats.
    private func detail(_ index: Int) {
        guard let plan, plan.steps.indices.contains(index) else { return }
        onStepDetail?(plan.steps[index], index + 1)
    }

    private func clear() {
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in steps.arrangedSubviews {
            steps.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stepButtons.removeAll()
}
