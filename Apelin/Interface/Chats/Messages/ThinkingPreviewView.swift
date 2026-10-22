import UIKit

/// One line under a running summary, at the reading width, between
/// hairlines on a faint grey ground that runs the row's whole width, showing
/// the latest thing the agent did.
/// Thinking text is pinned to the trailing edge, so the newest words stay in
/// view and the oldest fade off the leading one; it arrives in chunks and is
/// typed out a character at a time, the newest few fading in. A tool call
/// shows its reason, and a file edit the file's name with the lines added in
/// green and removed in red. The full record stays in the trace the summary
/// opens.
final class ThinkingPreviewView: UIView {
    static let height: CGFloat = 32
    /// Characters laid out from the end of the thinking text: enough to fill
    /// a wide line; the rest is never measured.
    private static let tailLength = 160

    private let label = UILabel()
    private let clip = UIView()
    private let fade = CAGradientLayer()
    /// The grey ground and its hairlines, drawn past the view's own edges
    /// to the row's: the line keeps the reading width, its ground does not.
    private let ground = UIView()
    private let topRule = UIView()
    private let bottomRule = UIView()
    private var shown: ActivityPreview?

    /// The thinking text received so far, and how much of it is typed out.
    private var thinking: [Character] = []
    private var revealed: Double = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// A chunk is typed out in about this long, however large; a trickle no
    /// slower than `minimumRate` characters a second.
    private static let catchUpDuration: Double = 0.35
    private static let minimumRate: Double = 60
    /// The newest characters fade in over this many.
    private static let fadeLength = 8

    /// How far the ground reaches past each side, set by the row.
    var groundBleed = UIEdgeInsets.zero {
        didSet {
            if groundBleed != oldValue {
                setNeedsLayout()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        ground.backgroundColor = UIColor.systemGray.withAlphaComponent(0.05)
        addSubview(ground)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        label.numberOfLines = 1
        clip.clipsToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear.cgColor, UIColor.white.cgColor]
        fade.locations = [0, 0.15]
        clip.addSubview(label)
        addSubview(clip)
        for rule in [topRule, bottomRule] {
            rule.backgroundColor = .separator
            ground.addSubview(rule)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    /// A call fades in. Thinking text is typed out from where the previous
    /// chunk had got to; a new thought starts from its first character. The
    /// first text a line shows, any text off screen and everything under
    /// Reduce Motion appear at once.
    func show(_ preview: ActivityPreview) {
        guard preview != shown else { return }
        let previous = shown
        shown = preview
        label.layer.removeAllAnimations()
        switch preview {
        case let .thinking(text):
            let characters = Array(text)
            let continues = characters.count >= thinking.count && characters.starts(with: thinking)
            if case .thinking = previous, continues, animates {
                // the same thought, longer: keep typing where it was
            } else if case .thinking = previous, animates {
                revealed = 0
            } else {
                revealed = Double(characters.count)
            }
            thinking = characters
            label.lineBreakMode = .byClipping
            clip.layer.mask = fade
            renderThinking()
            updateLink()
            return
        case let .tool(reason, file, change):
            stopLink()
            label.attributedText = Self.toolLine(reason: reason, file: file, change: change)
            label.lineBreakMode = .byTruncatingTail
            clip.layer.mask = nil
            if previous != nil, window != nil, !UIAccessibility.isReduceMotionEnabled {
                let fadeIn = CATransition()
                fadeIn.type = .fade
                fadeIn.duration = 0.2
                label.layer.add(fadeIn, forKey: "content")
            }
        }
        layoutLabel()
    }

    func reset() {
        shown = nil
        thinking = []
        revealed = 0
        stopLink()
        label.attributedText = nil
        label.layer.removeAllAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, case .thinking = shown {
            // nobody sees it type: show it whole
            revealed = Double(thinking.count)
            renderThinking()
        }
        updateLink()
    }

    private var animates: Bool {
        window != nil && !UIAccessibility.isReduceMotionEnabled
    }

    private var isTyping: Bool {
        if case .thinking = shown {
            return revealed < Double(thinking.count)
        }
        return false
    }

    private func updateLink() {
        guard isTyping, animates else {
            stopLink()
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let elapsed = lastTick == 0 ? link.duration : min(now - lastTick, 0.1)
        lastTick = now
        let backlog = Double(thinking.count) - revealed
        let rate = max(Self.minimumRate, backlog / Self.catchUpDuration)
        revealed = min(Double(thinking.count), revealed + rate * elapsed)
        renderThinking()
        if !isTyping {
            stopLink()
        }
    }

    /// The typed part's tail, its newest characters fading in by how far
    /// typing has got through them.
    private func renderThinking() {
        let count = Int(revealed.rounded(.up))
        let start = max(0, count - Self.tailLength)
        let text = Self.line(String(thinking[start ..< min(count, thinking.count)]))
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let color = UIColor.secondaryLabel.resolvedColor(with: traitCollection)
        var alpha: CGFloat = 1
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        // the dynamic colour at rest, so a change of appearance reaches it
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel],
        )
        let characters = Array(text)
        let fading = min(Self.fadeLength, characters.count)
        if fading > 0, isTyping {
            let partial = revealed - revealed.rounded(.down)
            var offset = text.utf16.count
            for index in 0 ..< fading {
                let character = characters[characters.count - 1 - index]
                let length = String(character).utf16.count
                offset -= length
                // 0 for the character being typed, 1 once `fadeLength` more follow it
                let progress = min(1, max(0, (Double(index) + (partial == 0 ? 1 : partial)) / Double(Self.fadeLength)))
                result.addAttribute(
                    .foregroundColor,
                    value: color.withAlphaComponent(alpha * CGFloat(progress)),
                    range: NSRange(location: offset, length: length),
                )
            }
        }
        label.attributedText = result
        layoutLabel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rule = 1 / max(traitCollection.displayScale, 1)
        ground.frame = bounds.inset(
            by: UIEdgeInsets(top: 0, left: -groundBleed.left, bottom: 0, right: -groundBleed.right),
        )
        topRule.frame = CGRect(x: 0, y: 0, width: ground.bounds.width, height: rule)
        bottomRule.frame = CGRect(x: 0, y: ground.bounds.height - rule, width: ground.bounds.width, height: rule)
        clip.frame = bounds.insetBy(dx: ChatMessageRow.horizontalPadding, dy: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = clip.bounds
        CATransaction.commit()
        layoutLabel()
    }

    /// Thinking is as wide as its text and pinned to the trailing edge, so
    /// the newest words stay in view and the clip cuts the oldest. A call
    /// fills the line from the leading edge and truncates its end.
    private func layoutLabel() {
        let size = label.intrinsicContentSize
        let y = (clip.bounds.height - size.height) / 2
        if case .thinking = shown {
            label.frame = CGRect(x: clip.bounds.width - size.width, y: y, width: size.width, height: size.height)
        } else {
            label.frame = CGRect(x: 0, y: y, width: clip.bounds.width, height: size.height)
        }
    }

    private static func line(_ text: String) -> String {
        text.suffix(tailLength).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "Tweak.x +12 −3  Hook the lock screen": the file and its counts lead,
    /// so truncation takes the end of the reason, never the numbers.
    private static func toolLine(
        reason: String,
        file: String?,
        change: ActivityPreview.LineChange?,
    ) -> NSAttributedString {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        let figures = UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .medium)
        let result = NSMutableAttributedString()
        func append(_ text: String, _ font: UIFont, _ color: UIColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        if let file {
            append(file, UIFont.systemFont(ofSize: font.pointSize, weight: .medium), .label)
            if let change {
                append("  +\(change.added)", figures, .systemGreen)
                append(" −\(change.removed)", figures, .systemRed)
            }
            append("  ", font, .secondaryLabel)
        }
        append(Self.line(reason), font, .secondaryLabel)
        return result
    }
}

/// The display link's target, which would otherwise keep the view alive.
private final class WeakTarget: NSObject {
    weak var view: ThinkingPreviewView?

    init(_ view: ThinkingPreviewView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.tick(link)
    }
}
