import UIKit

/// A row of reply buttons that sends a predefined text as the reader's
/// next message, so common answers do not have to be typed.
final class ComposerQuickReplySection: ComposerSectionView {
    var onReply: ((String) -> Void)?

    private var replies: [String] = []
    var isPresentingReplies: Bool { !replies.isEmpty }
    private let stack = UIStackView()

    override func initializeViews() {
        super.initializeViews()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.distribution = .fillEqually
        addSubview(stack)
        alpha = 0
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    func show(_ replies: [String]) {
        guard self.replies != replies else { return }
        self.replies = replies
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for reply in replies {
            let button = UIButton(type: .system)
            var style = UIButton.Configuration.tinted()
            style.title = reply
            style.cornerStyle = .medium
            style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .preferredFont(forTextStyle: .subheadline)
                return attributes
            }
            button.configuration = style
            button.addAction(UIAction { [weak self] _ in self?.onReply?(reply) }, for: .touchUpInside)
            button.accessibilityLabel = reply
            stack.addArrangedSubview(button)
        }
        let visible = !replies.isEmpty
        alpha = visible ? 1 : 0
        isUserInteractionEnabled = visible
        accessibilityElementsHidden = !visible
        heightPublisher.send(visible ? layoutContent() : 0)
        superview?.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !replies.isEmpty else { return }
        heightPublisher.send(layoutContent())
    }

    @discardableResult
    private func layoutContent() -> CGFloat {
        let width = max(1, bounds.width + horizontalAdjustment)
        let buttonHeight = max(36, ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight + 16))
        stack.frame = CGRect(x: 0, y: 0, width: width, height: buttonHeight)
        return buttonHeight + 8
    }
}
