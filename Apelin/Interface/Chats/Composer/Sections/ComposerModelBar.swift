// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import ApelinProtocol
import UIKit

/// FlowDown's model control below the text band, hidden while imports are open.
final class ComposerModelBar: ComposerSectionView {
    let button = ComposerBlockButton(text: String(localized: "Select Model"), image: UIImage(named: "ComposerModel"))
    /// The key that sends, when more than one of them can answer with the
    /// model shown: switching keeps the model, the conversation and its
    /// history, which is the one change that costs the reader nothing.
    private let keyButton = ComposerBlockButton(text: "", image: UIImage(systemName: "key"))
    private let effortButton = ComposerBlockButton(text: String(localized: "High"), image: UIImage(systemName: "brain"))
    private let tierButton = ComposerBlockButton(text: String(localized: "Standard"), image: UIImage(systemName: "bolt"))
    private let stopButton = ComposerBlockButton(
        text: String(localized: "Stop"),
        image: UIImage(systemName: "stop.fill"),
    )
    /// Answers a model that ran out of allowance with the next one, for the
    /// reader who does not want to wait for the automatic tries.
    private let retryButton = ComposerBlockButton(
        text: String(localized: "Retry"),
        image: UIImage(systemName: "arrow.clockwise"),
    )
    var onEffortChanged: ((AgentReasoningEffort) -> Void)?
    var onTierChanged: ((AgentServiceTier?) -> Void)?
    var onRetry: (() -> Void)?
    /// The key the reader picked, which sends the model shown from now on.
    var onKeyChanged: ((AgentAccount) -> Void)?
    private var keyIDs: [String] = []
    private var currentKeyID: String?
    private var cancelOutput: (() -> Void)?

    override func initializeViews() {
        super.initializeViews()
        for control in [button, keyButton, effortButton, tierButton, retryButton, stopButton] {
            addSubview(control)
        }
        keyButton.showsMenuAsPrimaryAction = true
        keyButton.tintColor = .secondaryLabel
        setControl(keyButton, visible: false)
        effortButton.showsMenuAsPrimaryAction = true
        setControl(effortButton, visible: false)
        tierButton.showsMenuAsPrimaryAction = true
        setControl(tierButton, visible: false)
        retryButton.tintColor = .systemOrange
        retryButton.borderColor = .systemOrange.withAlphaComponent(0.5)
        setControl(retryButton, visible: false)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        stopButton.tintColor = .systemRed
        stopButton.borderColor = .systemRed.withAlphaComponent(0.5)
        stopButton.accessibilityLabel = String(localized: "Stop Generating")
        setControl(stopButton, visible: false)
        stopButton.addAction(UIAction { [weak self] _ in self?.cancelOutput?() }, for: .touchUpInside)
        setModelName(nil)
        setVisible(true)
    }

    func setModelName(_ name: String?) {
        updateControls { [self] in
            button.setText(name ?? String(localized: "Select Model"))
            button.accessibilityLabel = String(localized: "Select Model")
            button.accessibilityValue = name
        }
    }

    /// The keys that can send the model shown, when more than one can: the
    /// row then offers the switch, and hides it again when a single key
    /// answers, which says nothing the model button does not. Each key is
    /// named the way Settings names it — a title, never a secret.
    func setKeys(_ keys: [AgentAccount], selected: AgentAccount?) {
        let ids = keys.map(\.id)
        guard ids != keyIDs || selected?.id != currentKeyID else { return }
        keyIDs = ids
        currentKeyID = selected?.id
        let name = selected?.title
        updateControls { [self] in
            setControl(keyButton, visible: keys.count > 1)
            keyButton.setText(name ?? "")
            keyButton.accessibilityLabel = String(localized: "API Key")
            keyButton.accessibilityValue = name
        }
        keyButton.menu = keys.count > 1
            ? UIMenu(children: keys.map { account in
                UIAction(
                    title: account.title,
                    state: account.id == selected?.id ? .on : .off,
                ) { [weak self] _ in
                    self?.onKeyChanged?(account)
                }
            })
            : nil
    }

    /// The import panel takes this row's place, so the row hands over to it.
    func setVisible(_ visible: Bool) {
        handOver(visible: visible)
        updateControls { [self] in
            isUserInteractionEnabled = visible
            accessibilityElementsHidden = !visible
            heightPublisher.send(visible ? button.intrinsicContentSize.height : 0)
        }
    }

    func setEfforts(_ efforts: [AgentReasoningEffort], selected: AgentReasoningEffort?) {
        updateControls { [self] in
            setControl(effortButton, visible: !efforts.isEmpty)
            effortButton.setText(Self.title(for: selected ?? .high))
            effortButton.accessibilityLabel = String(localized: "Reasoning Effort")
            effortButton.accessibilityValue = Self.title(for: selected ?? .high)
        }
        effortButton.menu = UIMenu(children: efforts.map { effort in
            UIAction(title: Self.title(for: effort), state: effort == selected ? .on : .off) { [weak self] _ in
                self?.setEfforts(efforts, selected: effort)
                self?.onEffortChanged?(effort)
            }
        })
    }

    /// The standard tier first, then the faster ones the model offers;
    /// hidden for a model that offers none.
    func setTiers(_ tiers: [AgentServiceTier], selected: AgentServiceTier?) {
        updateControls { [self] in
            setControl(tierButton, visible: !tiers.isEmpty)
            tierButton.setText(Self.title(for: selected))
            tierButton.accessibilityLabel = String(localized: "Speed")
            tierButton.accessibilityValue = Self.title(for: selected)
        }
        tierButton.menu = UIMenu(children: ([nil] + tiers).map { tier in
            UIAction(title: Self.title(for: tier), state: tier == selected ? .on : .off) { [weak self] _ in
                self?.setTiers(tiers, selected: tier)
                self?.onTierChanged?(tier)
            }
        })
    }

    /// The owner supplies its live run's cancellation; absent means no output to stop.
    func setOutputCancellation(_ cancel: (() -> Void)?) {
        cancelOutput = cancel
        updateControls { [self] in setControl(stopButton, visible: cancel != nil) }
    }

    /// Shown while a model is left to answer the reader's last message
    /// again, and nothing is running that a second prompt would join.
    func setRetry(_ available: Bool) {
        updateControls { [self] in setControl(retryButton, visible: available) }
    }

    private func setControl(_ control: UIButton, visible: Bool) {
        control.alpha = visible ? 1 : 0
        control.isUserInteractionEnabled = visible
        control.accessibilityElementsHidden = !visible
    }

    private func updateControls(_ changes: @escaping () -> Void) {
        let update = { [self] in
            changes()
            setNeedsLayout()
            layoutIfNeeded()
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            doWithAnimation(update)
        } else {
            UIView.performWithoutAnimation(update)
        }
    }

    private static func title(for effort: AgentReasoningEffort) -> String {
        switch effort {
        case .off: String(localized: "Off")
        case .minimal: String(localized: "Minimal")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra High")
        case .max: String(localized: "Maximum")
        }
    }

    private static func title(for tier: AgentServiceTier?) -> String {
        switch tier {
        case nil: String(localized: "Standard")
        case .priority: String(localized: "Fast")
        case .ultrafast: String(localized: "Ultrafast")
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let controls = [button, keyButton, effortButton, tierButton, retryButton, stopButton]
            .filter(\.isUserInteractionEnabled)
        let spacing: CGFloat = 10
        let otherWidth = controls.dropFirst().reduce(CGFloat.zero) { $0 + $1.intrinsicContentSize.width + spacing }
        let modelWidth = min(button.intrinsicContentSize.width, max(44, bounds.width - otherWidth))
        var x = max(0, (bounds.width - modelWidth - otherWidth) / 2)
        // model, key, effort, speed, Retry, Stop in reading order: right to left, from the right
        for control in [button, keyButton, effortButton, tierButton, retryButton, stopButton] {
            let width = control === button ? modelWidth : control.intrinsicContentSize.width
            control.frame = directionalFrame(
                CGRect(x: x, y: 0, width: width, height: control.intrinsicContentSize.height),
            )
            if control.isUserInteractionEnabled {
                x += width + spacing
            }
        }
    }
}
