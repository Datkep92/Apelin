import ApelinProtocol
import UIKit

/// The outstanding decision replaces the input. Only its result enters history.
final class ComposerApprovalSection: ComposerSectionView {
    /// The request and the decision; Approve on a request as root waits on
    /// the device owner's check there before anything is sent.
    var onDecision: ((ChatMessage, ApprovalDecision) -> Void)?
    private var request: ChatMessage?
    var isPresentingRequest: Bool {
        request != nil
    }

    private let titleLabel = UILabel()
    /// Shown only for a command that runs as root, between the title and
    /// the detail, so it is read before the command.
    private let rootLabel = UILabel()
    private let detailLabel = UILabel()
    /// The title and detail: a request taller than half the window scrolls
    /// from its start, under buttons that stay in place.
    private let textScroll = UIScrollView()
    private let approveButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)

    override func initializeViews() {
        super.initializeViews()
        clipsToBounds = true
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 0
        // Drawn at the final size and pinned to the top, not stretched, while a frame animates.
        titleLabel.contentMode = .topLeft
        titleLabel.accessibilityTraits.insert(.header)
        let subheadline = UIFont.preferredFont(forTextStyle: .subheadline)
        rootLabel.font = subheadline.fontDescriptor.withSymbolicTraits(.traitBold)
            .map { UIFont(descriptor: $0, size: 0) } ?? subheadline
        rootLabel.textColor = .systemRed
        rootLabel.numberOfLines = 0
        rootLabel.contentMode = .topLeft
        rootLabel.text = String(localized: "Runs as root, with full control of this device")
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.contentMode = .topLeft
        var approveStyle = UIButton.Configuration.tinted()
        approveStyle.background.strokeColor = .tintColor.withAlphaComponent(0.35)
        approveStyle.background.strokeWidth = 1
        approveStyle.titleLineBreakMode = .byTruncatingTail
        approveStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .headline)
            return attributes
        }
        approveButton.configuration = approveStyle
        approveButton.setTitle(String(localized: "Approve"), for: .normal)
        var denyStyle = UIButton.Configuration.tinted()
        denyStyle.titleLineBreakMode = .byTruncatingTail
        denyButton.configuration = denyStyle
        denyButton.setTitle(String(localized: "Deny"), for: .normal)
        denyButton.tintColor = .secondaryLabel
        approveButton.addAction(UIAction { [weak self] _ in self?.decide(.approve) }, for: .touchUpInside)
        denyButton.addAction(UIAction { [weak self] _ in self?.decide(.deny) }, for: .touchUpInside)
        textScroll.contentInsetAdjustmentBehavior = .never
        for view in [titleLabel, rootLabel, detailLabel] {
            textScroll.addSubview(view)
        }
        for view in [textScroll, denyButton, approveButton] {
            addSubview(view)
        }
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    func show(_ message: ChatMessage?) {
        guard request != message else { return }
        let replacing = request != nil
        if let message, !replacing {
            // Placed while still hidden, so the content is revealed by the
            // card rather than growing out of a zero frame.
            UIView.performWithoutAnimation {
                setText(of: message)
                layoutContent()
            }
        }
        let update = { [self] in
            request = message
            if let message, replacing {
                for label in [titleLabel, rootLabel, detailLabel] {
                    UIView.transition(
                        with: label,
                        duration: 0.25,
                        options: [.transitionCrossDissolve, .allowUserInteraction],
                    ) {}
                }
                setText(of: message)
            }
            let visible = message != nil
            alpha = visible ? 1 : 0
            isUserInteractionEnabled = visible
            accessibilityElementsHidden = !visible
            heightPublisher.send(visible ? layoutContent() : 0)
            // The composer's layout follows whether a request is shown, not only this band's height.
            superview?.setNeedsLayout()
        }
        if window != nil, !UIAccessibility.isReduceMotionEnabled {
            (superview ?? self).doWithAnimation(update)
        } else {
            UIView.performWithoutAnimation(update)
        }
    }

    private func setText(of message: ChatMessage) {
        titleLabel.text = message.approvalTitle
        rootLabel.isHidden = !message.runsAsRoot
        detailLabel.text = message.approvalDetail
        textScroll.contentOffset = .zero
    }

    private func decide(_ decision: ApprovalDecision) {
        guard let request else { return }
        onDecision?(request, decision)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard request != nil else { return }
        heightPublisher.send(layoutContent())
    }

    /// Places the content for the current width and answers the height it needs.
    @discardableResult
    private func layoutContent() -> CGFloat {
        let contentWidth = max(1, bounds.width)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
        )
        titleLabel.frame = CGRect(x: 0, y: ChatMarkdownView.blockSpacing, width: contentWidth, height: titleHeight)
        var textBottom = titleLabel.frame.maxY
        if !rootLabel.isHidden {
            let rootHeight = ceil(
                rootLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
            )
            rootLabel.frame = CGRect(x: 0, y: textBottom + ChatMarkdownView.blockSpacing / 2, width: contentWidth, height: rootHeight)
            textBottom = rootLabel.frame.maxY
        }
        let detailHeight = ceil(
            detailLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height,
        )
        detailLabel.frame = CGRect(
            x: 0,
            y: textBottom + ChatMarkdownView.blockSpacing,
            width: contentWidth,
            height: detailHeight,
        )
        let textHeight = detailLabel.frame.maxY
        textScroll.contentSize = CGSize(width: contentWidth, height: textHeight)
        textScroll.frame = CGRect(
            x: 0,
            y: 0,
            width: contentWidth,
            height: min(textHeight, (window?.bounds.height ?? .greatestFiniteMagnitude) / 2),
        )
        let buttonWidth = (contentWidth - ChatMarkdownView.blockSpacing) / 2
        let actionY = textScroll.frame.maxY + ChatMarkdownView.blockSpacing
        // Deny then Approve in reading order: right to left, Deny on the right
        let row = CGRect(x: 0, y: actionY, width: contentWidth, height: 44)
        let deny = CGRect(x: 0, y: actionY, width: buttonWidth, height: 44)
        denyButton.frame = directionalFrame(deny, across: row)
        approveButton.frame = directionalFrame(
            CGRect(x: deny.maxX + ChatMarkdownView.blockSpacing, y: actionY, width: buttonWidth, height: 44),
            across: row,
        )
        return approveButton.frame.maxY + ChatMarkdownView.blockSpacing
    }
}
