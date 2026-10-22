import ListViewKit
import MarkdownView
import UIKit

/// Thinking and tool events stay separate in the transcript's original order.
final class ChatActivityRow: ListRowView {
    var onToggle: (() -> Void)?
    private let header = ThinkingStatusLabel()
    private let preview = ThinkingPreviewView()
    private let body = ChatMarkdownView()
    private static let sizingBody = ChatMarkdownView()
    private static let sizingHeader = ThinkingStatusLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        addSubview(header)
        addSubview(preview)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggle)))
        addSubview(body)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage, includesThoughts: Bool = false) {
        header.animationIdentity = message.id
        header.text = message.activityTitle
        isAccessibilityElement = false
        header.accessibilityLabel = message.activityTitle
        // a summary in the transcript opens its trace; rows inside the trace only read
        let opensTrace = !includesThoughts && Self.isReasoning(message)
        header.accessibilityValue = nil
        header.accessibilityTraits = opensTrace ? .button : .staticText
        header.accessibilityCustomActions = opensTrace
            ? [UIAccessibilityCustomAction(name: String(localized: "View Thoughts")) { [weak self] _ in
                self?.onToggle?(); return true
            }]
            : nil
        if let shown = Self.preview(of: message, includesThoughts: includesThoughts) {
            preview.show(shown)
            preview.isHidden = false
        } else {
            preview.reset()
            preview.isHidden = true
        }
        if case let .thinking(seconds, _) = message.role {
            header.isThinking = seconds == nil
            body.isHidden = !includesThoughts || message.text.isEmpty
            body.setMarkdown(body.isHidden ? "" : message.text)
        } else {
            header.isThinking = false
            body.isHidden = !includesThoughts || message.detail.isEmpty
            body.setMarkdown(body.isHidden ? "" : message.detail)
        }
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        header.isThinking = false
        preview.reset()
        preview.isHidden = true
        header.animationIdentity = nil
        header.text = nil
        onToggle = nil
        body.reset()
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
        var top = header.frame.maxY
        if !preview.isHidden {
            // the line keeps the reading width, padding included; its
            // ground is drawn out to the row's edges
            let padding = ChatMessageRow.horizontalPadding
            preview.frame = CGRect(
                x: content.minX - padding,
                y: top + Self.previewSpacing,
                width: content.width + padding * 2,
                height: ThinkingPreviewView.height,
            )
            preview.groundBleed = UIEdgeInsets(
                top: 0,
                left: max(0, preview.frame.minX),
                bottom: 0,
                right: max(0, bounds.width - preview.frame.maxX),
            )
            top = preview.frame.maxY
        }
        body.frame = CGRect(
            x: content.minX,
            y: top + ChatMarkdownView.blockSpacing,
            width: content.width,
            height: max(0, content.maxY - top - ChatMarkdownView.blockSpacing),
        )
        body.trackedScrollView = superview as? UIScrollView
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
        if preview(of: message, includesThoughts: includesThoughts) != nil {
            height += previewSpacing + ThinkingPreviewView.height
        }
        let text: String = if case .thinking = message.role {
            includesThoughts ? message.text : ""
        } else {
            includesThoughts ? message.detail : ""
        }
        if !text.isEmpty {
            sizingBody.setMarkdown(text)
            height += ChatMarkdownView.blockSpacing + ceil(sizingBody.boundingSize(for: width).height)
        }
        return height
    }

    private static let previewSpacing: CGFloat = 8

    /// Only a running summary in the transcript has the preview line; the
    /// trace sheet shows the whole thinking instead.
    private static func preview(of message: ChatMessage, includesThoughts: Bool) -> ActivityPreview? {
        guard !includesThoughts, message.role.isThinking else { return nil }
        return message.preview
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
