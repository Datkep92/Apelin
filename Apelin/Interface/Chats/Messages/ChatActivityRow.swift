import ListViewKit
import Litext
import UIKit

/// A summary in the transcript, or a step in its trace. A running summary's
/// title is followed by the output the run has received so far, and its
/// newest call is the line under it. In the trace, a step's thinking, or a
/// call's arguments one by one and its result (`TraceBody`), follow as plain
/// selectable text.
final class ChatActivityRow: ListRowView {
    var onToggle: (() -> Void)?
    private let header = ThinkingStatusLabel()
    private let received = ReceivedTokensView()
    private let bannerView = ToolCallBannerView()
    private let body = TextLabelView()
    /// What the body shows, nil when it shows nothing.
    private var bodyKey: TraceBody.Key?
    /// The message this row shows: only a change to it animates, never the
    /// row taking another message out of the pool.
    private var shownID: UUID?
    /// Whether the count is meant to be on screen, while it fades too.
    private var showsReceived = false
    private static let sizingHeader = ThinkingStatusLabel()
    /// Between the title and the count after it.
    private static let receivedSpacing: CGFloat = 6
    /// Between the title and the line under it.
    private static let bannerSpacing: CGFloat = 8

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Selection handles extend beyond a row.
        clipsToBounds = false
        addSubview(header)
        received.isHidden = true
        addSubview(received)
        bannerView.isHidden = true
        addSubview(bannerView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        body.isSelectable = true
        body.delegate = self
        body.isAccessibilityElement = true
        addSubview(body)
        header.onShownTextChange = { [weak self] animated in
            self?.titleChanged(animated: animated)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage, includesThoughts: Bool = false) {
        let isSameMessage = shownID == message.id
        shownID = message.id
        header.animationIdentity = message.id
        header.text = message.activityTitle
        isAccessibilityElement = false
        header.accessibilityLabel = message.activityTitle
        // a summary in the transcript opens its trace; rows inside the trace only read
        let opensTrace = !includesThoughts && Self.isReasoning(message)
        header.accessibilityTraits = opensTrace ? .button : .staticText
        header.accessibilityCustomActions = opensTrace
            ? [UIAccessibilityCustomAction(name: String(localized: "View Thoughts")) { [weak self] _ in
                self?.onToggle?(); return true
            }]
            : nil
        let tokens = Self.receivedTokens(of: message, includesThoughts: includesThoughts)
        header.accessibilityValue = tokens.map(ReceivedTokensView.spoken)
        showReceived(tokens, animated: isSameMessage)
        if let call = Self.banner(of: message, includesThoughts: includesThoughts) {
            bannerView.show(call, animated: isSameMessage)
            bannerView.isHidden = false
        } else {
            bannerView.reset()
            bannerView.isHidden = true
        }
        header.isThinking = message.role.isThinking
        showBody(includesThoughts ? TraceBody.key(for: message) : nil)
        setNeedsLayout()
    }

    /// The trace updates live: a step that did not change keeps its selection.
    private func showBody(_ key: TraceBody.Key?) {
        body.isHidden = key == nil
        guard key != bodyKey else { return }
        bodyKey = key
        body.clearSelection()
        body.attributedText = key.map(TraceBody.text) ?? NSAttributedString()
        body.accessibilityLabel = key == nil ? nil : body.attributedText.string
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // the text is set in the size it was built for
        guard let key = bodyKey, key.size != UIApplication.shared.preferredContentSizeCategory else { return }
        showBody(TraceBody.Key(
            source: key.source,
            callTitle: key.callTitle,
            size: UIApplication.shared.preferredContentSizeCategory,
        ))
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        shownID = nil
        header.isThinking = false
        header.animationIdentity = nil
        header.text = nil
        header.accessibilityValue = nil
        showsReceived = false
        received.layer.removeAllAnimations()
        received.isHidden = true
        received.alpha = 1
        bannerView.reset()
        bannerView.isHidden = true
        onToggle = nil
        bodyKey = nil
        body.clearSelection()
        body.attributedText = NSAttributedString()
        body.accessibilityLabel = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
        let textWidth = max(1, content.width)
        let scale = max(traitCollection.displayScale, 1)
        func pixel(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let height = ceil(header.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        header.frame = CGRect(
            x: pixel(content.minX),
            y: pixel(content.minY),
            width: pixel(textWidth),
            height: pixel(height),
        )
        layoutReceived(in: content)
        var top = header.frame.maxY
        if !bannerView.isHidden {
            // the line keeps the reading width, padding included; its
            // ground is drawn out to the row's edges
            let padding = ChatMessageRow.horizontalPadding
            bannerView.frame = CGRect(
                x: content.minX - padding,
                y: top + Self.bannerSpacing,
                width: content.width + padding * 2,
                height: ToolCallBannerView.height,
            )
            bannerView.groundBleed = UIEdgeInsets(
                top: 0,
                left: max(0, bannerView.frame.minX),
                bottom: 0,
                right: max(0, bounds.width - bannerView.frame.maxX),
            )
            top = bannerView.frame.maxY
        }
        // measured as `height(for:)` measures it
        let bodyHeight = bodyKey.map { TraceBody.height(for: $0, width: textWidth) } ?? 0
        body.frame = CGRect(
            x: content.minX,
            y: top + ChatMarkdownView.blockSpacing,
            width: textWidth,
            height: bodyHeight,
        )
    }

    /// On the title's first line, after the text it draws now.
    private func layoutReceived(in content: CGRect) {
        guard !received.isHidden else { return }
        let x = content.minX + header.shownTextWidth + Self.receivedSpacing
        let size = received.sizeThatFits(.zero)
        let line = ceil(header.font.lineHeight)
        received.frame = directionalFrame(CGRect(
            x: x,
            y: header.frame.minY + ((line - size.height) / 2).rounded(),
            width: max(0, min(size.width, content.maxX - x)),
            height: size.height,
        ))
    }

    /// The count follows its title when the title rolls to another width.
    private func titleChanged(animated: Bool) {
        setNeedsLayout()
        guard animated, !received.isHidden, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
        ) {
            self.layoutIfNeeded()
        }
    }

    /// A count that appears or goes on the same summary fades; one on
    /// another summary, off screen or under Reduce Motion is there at once.
    private func showReceived(_ tokens: Int?, animated: Bool) {
        if let tokens {
            received.show(tokens)
        }
        let shows = tokens != nil
        guard shows != showsReceived else { return }
        showsReceived = shows
        let fades = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
        received.layer.removeAllAnimations()
        if shows {
            received.isHidden = false
            // in place before it fades in, not moving in from elsewhere
            setNeedsLayout()
            layoutIfNeeded()
            received.alpha = fades ? 0 : 1
            if fades {
                UIView.animate(withDuration: 0.2) { self.received.alpha = 1 }
            }
        } else if fades {
            UIView.animate(withDuration: 0.2) {
                self.received.alpha = 0
            } completion: { _ in
                guard !self.showsReceived else { return }
                self.received.isHidden = true
                self.received.alpha = 1
            }
        } else {
            received.isHidden = true
            received.alpha = 1
        }
    }

    static func height(for message: ChatMessage, width: CGFloat, includesThoughts: Bool = false) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let width = max(1, width - insets.left - insets.right)
        sizingHeader.font = .preferredFont(forTextStyle: .body)
        sizingHeader.text = message.activityTitle
        let headerHeight = ceil(
            sizingHeader.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height,
        )
        var height = headerHeight + insets.top + insets.bottom
        if banner(of: message, includesThoughts: includesThoughts) != nil {
            height += bannerSpacing + ToolCallBannerView.height
        }
        if includesThoughts, let key = TraceBody.key(for: message) {
            height += ChatMarkdownView.blockSpacing + TraceBody.height(for: key, width: width)
        }
        return height
    }

    /// Only a running summary in the transcript shows the count.
    private static func receivedTokens(of message: ChatMessage, includesThoughts: Bool) -> Int? {
        guard !includesThoughts, message.role.isThinking else { return nil }
        return message.receivedTokens
    }

    /// Only a running summary in the transcript has the line under it; the
    /// trace lists every call whole.
    private static func banner(of message: ChatMessage, includesThoughts: Bool) -> ToolCallBanner? {
        guard !includesThoughts, message.role.isThinking else { return nil }
        return message.banner
    }

    private static func isReasoning(_ message: ChatMessage) -> Bool {
        if case .thinking = message.role {
            return true
        }
        return false
    }

    @objc private func toggle() {
        onToggle?()
    }
}

extension ChatActivityRow: TextLabelViewDelegate {
    func textLabelView(
        _ label: TextLabelView,
        editMenuForSelection selection: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        ChatSelectionMenu.menu(for: label, selection: selection, suggestedActions: suggestedActions)
    }
}
