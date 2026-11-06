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
///
/// Visual: a floating rounded glass surface, sitting just above the composer,
/// with a compact header and (when opened) a small list of status-marked
/// steps and capsule action buttons.
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
    static let headerHeight: CGFloat = 52
    static let stepHeight: CGFloat = 36
    static let actionHeight: CGFloat = 42
    static let cornerRadius: CGFloat = 18
    static let surfaceInset: CGFloat = 12
    static let progressHeight: CGFloat = 4

    private let surface = UIView()
    private let content = UIStackView()
    private let header = UIButton(type: .system)
    private let chevron = UIImageView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidthConstraint: NSLayoutConstraint!
    private let scroll = UIScrollView()
    private let steps = UIStackView()
    private let more = UILabel()
    private let actions = UIStackView()
    private let pauseResume = UIButton(type: .system)
    private let endPlan = UIButton(type: .system)
    private let clearPlan = UIButton(type: .system)

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)

        surface.layer.cornerRadius = Self.cornerRadius
        surface.layer.cornerCurve = .continuous
        surface.clipsToBounds = true
        addSubview(surface)
        surface.snp.makeConstraints { make in
            make.edges.equalTo(self).inset(UIEdgeInsets(
                top: 2,
                left: Self.surfaceInset,
                bottom: 2,
                right: Self.surfaceInset
            ))
        }

        let background: UIVisualEffectView
        if #available(iOS 26, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            background = UIVisualEffectView(effect: glass)
        } else {
            background = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        }
        background.layer.cornerRadius = Self.cornerRadius
        background.layer.cornerCurve = .continuous
        background.clipsToBounds = true
        surface.addSubview(background)
        background.snp.makeConstraints { $0.edges.equalToSuperview() }

        let separator = UIView()
        separator.backgroundColor = .separator.withAlphaComponent(0.35)
        surface.addSubview(separator)
        separator.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview()
            make.height.equalTo(1 / max(traitCollection.displayScale, 1))
        }

        content.axis = .vertical
        content.spacing = 6
        surface.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
        }

        var headerConfig = UIButton.Configuration.plain()
        headerConfig.image = UIImage(systemName: "checklist")
        headerConfig.imagePadding = 10
        headerConfig.contentInsets = .init(top: 0, leading: 12, bottom: 0, trailing: 36)
        headerConfig.background.cornerRadius = 10
        headerConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .subheadline).with(weight: .semibold)
            return outgoing
        }
        header.configuration = headerConfig
        header.contentHorizontalAlignment = .leading
        header.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).with(weight: .semibold)
        header.titleLabel?.numberOfLines = 1
        header.titleLabel?.lineBreakMode = .byTruncatingTail
        header.tintColor = .label
        header.addAction(UIAction { [weak self] _ in self?.toggle() }, for: .touchUpInside)
        header.layer.cornerRadius = 12
        header.layer.cornerCurve = .continuous
        chevron.image = UIImage(systemName: "chevron.compact.down")
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        header.addSubview(chevron)
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        header.snp.makeConstraints { make in
            make.height.equalTo(Self.headerHeight)
        }

        progressTrack.backgroundColor = .separator.withAlphaComponent(0.25)
        progressTrack.layer.cornerRadius = Self.progressHeight / 2
        progressTrack.clipsToBounds = true
        header.addSubview(progressTrack)
        progressTrack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(12)
            make.bottom.equalToSuperview().inset(8)
            make.height.equalTo(Self.progressHeight)
        }

        progressFill.backgroundColor = AppAccent.color(glass: .systemBlue)
        progressFill.layer.cornerRadius = Self.progressHeight / 2
        progressTrack.addSubview(progressFill)
        progressFill.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
        }
        progressWidthConstraint = progressFill.widthAnchor.constraint(equalToConstant: 0)
        progressWidthConstraint.isActive = true

        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.layer.cornerRadius = 10
        scroll.layer.cornerCurve = .continuous
        scroll.addSubview(steps)
        steps.axis = .vertical
        steps.spacing = 4
        steps.snp.makeConstraints { make in
            make.top.bottom.equalTo(scroll.contentLayoutGuide)
            make.leading.trailing.equalTo(scroll.frameLayoutGuide)
        }

        more.font = .preferredFont(forTextStyle: .footnote)
        more.textColor = .tertiaryLabel
        more.numberOfLines = 1
        more.isAccessibilityElement = true
        more.snp.makeConstraints { make in
            make.height.equalTo(Self.stepHeight)
        }

        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8
        configureButton(pauseResume, style: .filled)
        configureButton(endPlan, style: .outlined)
        configureButton(clearPlan, style: .outlined)

        pauseResume.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onAction?(self.plan?.state == .paused ? .resume : .pause)
        }, for: .touchUpInside)
        for (button, action) in [(endPlan, AgentPlanAction.cancel), (clearPlan, AgentPlanAction.clear)] {
            button.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside)
        }
        for button in [pauseResume, endPlan, clearPlan] {
            actions.addArrangedSubview(button)
        }
        setButtonTitle(endPlan, title: String(localized: "End plan"))
        setButtonTitle(clearPlan, title: String(localized: "Clear plan"))
        actions.snp.makeConstraints { make in
            make.height.equalTo(Self.actionHeight)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// The room it asks for: nothing at all when the conversation has no
    /// plan; otherwise the surface, the line, and (when opened) its steps
    /// and actions.
    var preferredHeight: CGFloat {
        guard let plan else { return 0 }
        let hairline = 1 / max(traitCollection.displayScale, 1)
        let verticalInset: CGFloat = 4
        guard isExpanded else {
            return hairline + verticalInset + Self.headerHeight + verticalInset
        }
        let shown = min(plan.steps.count, Self.visibleSteps)
        let beyond = plan.steps.count > shown ? Self.stepHeight : 0
        return hairline + verticalInset
            + Self.headerHeight + 6
            + (CGFloat(shown) * Self.stepHeight) + beyond + 6
            + Self.actionHeight + verticalInset
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
        let line = ChatPlan.line(for: plan)
        var config = header.configuration ?? .plain()
        config.title = line
        header.configuration = config
        header.accessibilityValue = line

        switch plan.state {
        case .cancelled: chevron.tintColor = .systemRed
        case .paused: chevron.tintColor = .systemOrange
        case .active: chevron.tintColor = .systemBlue
        }

        updateProgress(plan)
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
        setButtonTitle(pauseResume, title: plan.state == .paused ? String(localized: "Resume") : String(localized: "Pause"))
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
        let line = ChatPlan.line(for: plan)
        var config = header.configuration ?? .plain()
        config.title = line
        config.image = UIImage(systemName: plan.state == .cancelled ? "xmark.circle.fill"
                                 : (plan.state == .paused ? "pause.circle.fill" : "checklist"))
        header.configuration = config
        header.accessibilityLabel = String(localized: "Plan")
        header.accessibilityValue = line
        header.accessibilityHint = isExpanded
            ? String(localized: "Double tap to hide the steps")
            : String(localized: "Double tap to show the steps")
        chevron.image = UIImage(systemName: isExpanded ? "chevron.compact.up" : "chevron.compact.down")
        content.addArrangedSubview(header)
        updateProgress(plan)
        guard isExpanded else { return }

        for (index, step) in plan.steps.enumerated() {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setTitleColor(.label, for: .normal)
            button.setTitle("\(ChatPlan.glyph(step.status)) \(index + 1). \(step.title)", for: .normal)
            button.accessibilityLabel = "\(index + 1). \(step.title)"
            button.accessibilityValue = ChatPlan.detail(of: step)
            button.accessibilityHint = String(localized: "Double tap for the whole step")
            button.tag = index
            button.addAction(UIAction { [weak self] _ in self?.detail(index) }, for: .touchUpInside)
            button.snp.makeConstraints { make in make.height.equalTo(Self.stepHeight) }
            stepButtons.append(button)
            steps.addArrangedSubview(button)
        }
        content.addArrangedSubview(scroll)
        let shown = min(plan.steps.count, Self.visibleSteps)
        scroll.snp.remakeConstraints { make in make.height.equalTo(CGFloat(shown) * Self.stepHeight) }

        if plan.steps.count > shown {
            more.text = String(localized: "Scroll for the other steps")
            more.accessibilityLabel = String(localized: "More steps")
            content.addArrangedSubview(more)
        }

        setButtonTitle(pauseResume, title: plan.state == .paused ? String(localized: "Resume") : String(localized: "Pause"))
        pauseResume.isEnabled = plan.state != .cancelled
        endPlan.isEnabled = plan.state != .cancelled
        content.addArrangedSubview(actions)
    }

    private func updateProgress(_ plan: AgentPlan) {
        let done = max(0, plan.doneCount)
        let total = max(1, plan.steps.count)
        let ratio = min(1, max(0, CGFloat(done) / CGFloat(total)))
        let progressColor: UIColor = switch plan.state {
        case .active: AppAccent.color(glass: .systemBlue)
        case .paused: .systemOrange
        case .cancelled: .systemRed
        }
        progressFill.backgroundColor = progressColor
        self.layoutIfNeeded()
        progressWidthConstraint.constant = max(0, progressTrack.bounds.width * max(ratio, 0.02))
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.26
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut], animations: {
            self.progressTrack.layoutIfNeeded()
        }, completion: nil)
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

    private enum ButtonStyle { case filled, outlined }

    private func configureButton(_ button: UIButton, style: ButtonStyle) {
        switch style {
        case .filled:
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = AppAccent.color(glass: .systemBlue)
            config.baseForegroundColor = AppAccent.foreground(glass: .white)
            config.cornerStyle = .large
            config.titleLineBreakMode = .byTruncatingTail
            button.configuration = config
        case .outlined:
            var config = UIButton.Configuration.tinted()
            config.baseBackgroundColor = .clear
            config.baseForegroundColor = .label
            config.cornerStyle = .large
            config.titleLineBreakMode = .byTruncatingTail
            button.configuration = config
        }
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
    }

    private func setButtonTitle(_ button: UIButton, title: String) {
        var config = button.configuration ?? .plain()
        config.title = title
        button.configuration = config
    }
}

private extension UIFont {
    func with(weight: UIFont.Weight) -> UIFont {
        guard let descriptor = fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight]
        ]).withDesign(.default) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
