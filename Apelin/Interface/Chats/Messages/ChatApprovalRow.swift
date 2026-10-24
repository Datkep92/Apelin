import ApelinProtocol
import ListViewKit
import UIKit

/// Resolved approvals are one quiet header line; pending decisions replace the input.
final class ChatApprovalRow: ListRowView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label.withAlphaComponent(0.5)
        label.numberOfLines = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ message: ChatMessage) {
        label.text = message.approvalTitle
        if case let .approval(decision) = message.role {
            label.accessibilityValue = switch decision {
            case nil:
                message.runsAsRoot ? String(localized: "Root Approval Required") : String(localized: "Approval Required")
            case .approve: String(localized: "Allowed Once")
            case .deny: String(localized: "Denied")
            }
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: ChatMessageRow.insets(for: bounds.width))
    }

    static func height(for message: ChatMessage, width: CGFloat) -> CGFloat {
        let insets = ChatMessageRow.insets(for: width)
        let width = max(1, width - insets.left - insets.right)
        let rect = (message.approvalTitle as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
            context: nil,
        )
        return insets.top + max(22, ceil(rect.height)) + insets.bottom
    }
}
