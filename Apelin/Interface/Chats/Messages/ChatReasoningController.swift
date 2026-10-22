import ListViewKit
import UIKit

/// The full ordered trace lives in a sheet; the conversation shows one summary.
final class ChatReasoningController: UIViewController {
    let messageID: UUID
    private var message: ChatMessage
    private let list = ListView<ChatMessage>()

    init(message: ChatMessage) {
        self.message = message
        messageID = message.id
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(message:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Trace")
        view.backgroundColor = .pageBackground
        list.backgroundColor = .clear
        list.rows {
            ListRow(ChatActivityRow.self)
                .when { $0.role.isActivity }
                .height { message, context in
                    ChatActivityRow.height(for: message, width: context.width, includesThoughts: true)
                }
                .configure { row, message, _ in row.show(message, includesThoughts: true) }
            ListRow(ChatApprovalRow.self)
                .when { $0.role.isApproval }
                .height { message, context in ChatApprovalRow.height(for: message, width: context.width) }
                .configure { row, message, _ in row.show(message) }
        }
        view.addSubview(list)
        setContentScrollView(list)
        if #available(iOS 26, *) {
            list.topEdgeEffect.style = .soft
        }
        show(message)
    }

    func show(_ message: ChatMessage) {
        self.message = message
        guard isViewLoaded else { return }
        let trace = message.trace.isEmpty ? [message] : message.trace
        list.apply(trace, animated: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        list.frame = view.bounds
    }
}
