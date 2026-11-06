import Litext
import UIKit

/// One step of the trace, opened from its row: a thought's whole text, a
/// call's arguments by name and its result, or what an approval asked
/// (`TraceBody`), as plain selectable text. A step still streaming grows
/// here as it comes, below wherever the reader is.
final class TraceStepController: UIViewController {
    let stepID: UUID
    private let scrollView = UIScrollView()
    private let body = TextLabelView()
    /// What the body shows, nil when it shows nothing.
    private var key: TraceBody.Key?
    /// The text `key` makes and the height it takes at the width it was
    /// measured at: the page open holds its own step, so a layout pass does
    /// not decode a whole file again, and closing the page frees it —
    /// `TraceBody` keeps nothing. A width of 0 is "not measured yet".
    private var laid: (key: TraceBody.Key, text: NSAttributedString, width: CGFloat, height: CGFloat)?
    /// Between the text and the page's top and foot.
    private static let padding: CGFloat = 16

    init(step: ChatMessage, title: String) {
        stepID = step.id
        super.init(nibName: nil, bundle: nil)
        self.title = title
        body.isSelectable = true
        body.isAccessibilityElement = true
        body.accessibilityTraits = .staticText
        body.delegate = self
        show(step)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(step:title:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(body)
        view.addSubview(scrollView)
        setContentScrollView(scrollView)
    }

    /// A step that did not change keeps the reader's selection.
    func show(_ step: ChatMessage) {
        showBody(TraceBody.key(for: step))
    }

    private func showBody(_ key: TraceBody.Key?) {
        guard key != self.key else { return }
        self.key = key
        body.clearSelection()
        guard let key else {
            laid = nil
            body.attributedText = NSAttributedString()
            body.accessibilityLabel = nil
            viewIfLoaded?.setNeedsLayout()
            return
        }
        let text = TraceBody.text(for: key)
        laid = (key, text, 0, 0)
        body.attributedText = text
        body.accessibilityLabel = text.string
        viewIfLoaded?.setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // the text is set in the size it was built for
        let size = UIApplication.shared.preferredContentSizeCategory
        guard let key, key.size != size else { return }
        showBody(TraceBody.Key(source: key.source, callTitle: key.callTitle, size: size))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scrollView.frame = view.bounds
        let readable = view.readableContentGuide.layoutFrame
        guard readable.width > 0 else { return }
        // the height of the text this page shows, measured once at this width
        let height = laidHeight(at: readable.width)
        body.frame = CGRect(x: readable.minX, y: Self.padding, width: readable.width, height: height)
        scrollView.contentSize = CGSize(width: view.bounds.width, height: height + Self.padding * 2)
    }

    /// The height the step's text takes at `width`, measured once for it, so
    /// a run of layout passes does not decode and lay out a whole file again.
    private func laidHeight(at width: CGFloat) -> CGFloat {
        guard var laid else { return 0 }
        if laid.width != width {
            laid.width = width
            laid.height = TraceBody.height(of: laid.text, width: width)
            self.laid = laid
        }
        return laid.height
    }
}

extension TraceStepController: TextLabelViewDelegate {
    func textLabelView(
        _ label: TextLabelView,
        editMenuForSelection selection: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        var actions = suggestedActions
        let selected = label.attributedText.attributedSubstring(from: selection).string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = Self.previewURL(from: selected) {
            let open = UIAction(title: String(localized: "Open"), image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
                self?.presentPageAsFormSheet(WebBrowserController(url: url))
            }
            actions.insert(open, at: 0)
        }
        return UIMenu(children: actions)
    }

    private static func previewURL(from text: String) -> URL? {
        if let url = URL(string: text), url.scheme != nil {
            return url
        }
        // Treat an existing absolute local path as a file URL.
        if text.hasPrefix("/") {
            let url = URL(fileURLWithPath: text)
            if FileManager.default.fileExists(atPath: text) {
                return url
            }
        }
        return nil
    }
}
