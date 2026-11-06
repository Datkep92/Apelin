import Litext
import UIKit

/// The text a step's page in the trace shows (`TraceStepController`): a
/// thought's text, a call by `ToolCallDetail` with each name set apart from
/// its value, or what an approval asked. It keeps nothing: the page open
/// holds the one text it shows and the height it takes (`TraceStepController`),
/// so a long call (a whole file written) is decoded and laid out once while
/// its page is open, and the reader closing the page frees it — no step's
/// text outlives the page that showed it.
@MainActor
enum TraceBody {
    struct Key: Hashable {
        /// The thought's text, the call's detail, or the approval's card text.
        let source: String
        /// A call's title, whose repeat as `reason` is left out; nil for
        /// plain text, a thought's or an approval's.
        let callTitle: String?
        let size: UIContentSizeCategory
    }

    /// A step's key, or nil for a step with nothing to show.
    static func key(for message: ChatMessage) -> Key? {
        let size = UIApplication.shared.preferredContentSizeCategory
        switch message.role {
        case .thinking:
            return message.text.isEmpty ? nil : Key(source: message.text, callTitle: nil, size: size)
        case .approval:
            let detail = message.approvalDetail
            return detail.isEmpty ? nil : Key(source: detail, callTitle: nil, size: size)
        default:
            return message.detail.isEmpty ? nil : Key(source: message.detail, callTitle: message.text, size: size)
        }
    }

    /// The text a step's page shows, built for it.
    static func text(for key: Key) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ]
        guard let title = key.callTitle else {
            return NSAttributedString(string: key.source, attributes: body)
        }
        let footnote = UIFont.preferredFont(forTextStyle: .footnote)
        let name: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: footnote.pointSize, weight: .semibold),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let result = NSMutableAttributedString()
        for (index, section) in ToolCallDetail(detail: key.source, title: title).sections.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n", attributes: body))
            }
            if let label = section.name {
                result.append(NSAttributedString(string: label + "\n", attributes: name))
            }
            result.append(NSAttributedString(string: section.value, attributes: body))
        }
        return result
    }

    /// The height `text` takes at `width`, as a `TextLabelView` lays it out.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        sizing.attributedText = text
        return ceil(sizing.sizeThatFits(CGSize(width: width, height: 0)).height)
    }

    private static let sizing = TextLabelView()
}
