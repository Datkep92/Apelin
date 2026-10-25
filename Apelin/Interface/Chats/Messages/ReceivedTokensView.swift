import UIKit

/// After a running summary's title: the output tokens the run has received
/// so far, then a downward arrow, "653 ↓"; right to left, the arrow is on
/// the figure's left, still after it. The figure changes in place, its
/// digits all one width, as often as a count arrives, apart from the
/// title's own pace. VoiceOver reads it as the title's value, so the view
/// itself is hidden.
final class ReceivedTokensView: UIView {
    private let symbol = UIImageView(image: UIImage(systemName: "arrow.down"))
    private let label = UILabel()
    private static let spacing: CGFloat = 3

    var font = UIFont.preferredFont(forTextStyle: .body) {
        didSet { applyFont() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        // as the title is drawn when it is finished
        let color = UIColor.label.withAlphaComponent(0.5)
        symbol.tintColor = color
        symbol.contentMode = .center
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        addSubview(symbol)
        addSubview(label)
        applyFont()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ tokens: Int) {
        let figure = Self.figure(tokens)
        guard label.text != figure else { return }
        label.text = figure
        setNeedsLayout()
    }

    /// The count as it is drawn, grouped in the reader's locale: 1,234.
    static func figure(_ tokens: Int) -> String {
        tokens.formatted(.number)
    }

    /// What VoiceOver reads as the title's value.
    static func spoken(_ tokens: Int) -> String {
        tokens == 1
            ? String(localized: "1 token received")
            : String(localized: "\(figure(tokens)) tokens received")
    }

    override func sizeThatFits(_: CGSize) -> CGSize {
        let symbolSize = symbol.intrinsicContentSize
        let labelSize = label.intrinsicContentSize
        return CGSize(
            width: ceil(labelSize.width + Self.spacing + symbolSize.width),
            height: ceil(max(symbolSize.height, font.lineHeight)),
        )
    }

    /// The figure, then the arrow; given less than that, the figure gives
    /// way and the arrow stays whole.
    override func layoutSubviews() {
        super.layoutSubviews()
        let symbolWidth = symbol.intrinsicContentSize.width
        let labelWidth = max(0, min(label.intrinsicContentSize.width, bounds.width - Self.spacing - symbolWidth))
        label.frame = directionalFrame(CGRect(x: 0, y: 0, width: labelWidth, height: bounds.height))
        symbol.frame = directionalFrame(CGRect(
            x: labelWidth + Self.spacing,
            y: 0,
            width: symbolWidth,
            height: bounds.height,
        ))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        font = .preferredFont(forTextStyle: .body)
    }

    /// The arrow is drawn at the figure's font, so the two keep their sizes
    /// to each other at every text size.
    private func applyFont() {
        label.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: label.font)
        setNeedsLayout()
    }
}
