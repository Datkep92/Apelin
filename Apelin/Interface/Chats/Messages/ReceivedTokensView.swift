import UIKit

/// After a running summary's title: a downward arrow and the output tokens
/// the run has received so far. The figure changes in place, its digits all
/// one width, as often as a count arrives, apart from the title's own pace.
/// VoiceOver reads it as the title's value, so the view itself is hidden.
final class ReceivedTokensView: UIView {
    private let symbol = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
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
            width: ceil(symbolSize.width + Self.spacing + labelSize.width),
            height: ceil(max(symbolSize.height, font.lineHeight)),
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let symbolWidth = symbol.intrinsicContentSize.width
        symbol.frame = directionalFrame(CGRect(x: 0, y: 0, width: symbolWidth, height: bounds.height))
        let labelX = symbolWidth + Self.spacing
        label.frame = directionalFrame(CGRect(x: labelX, y: 0, width: max(0, bounds.width - labelX), height: bounds.height))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        font = .preferredFont(forTextStyle: .body)
    }

    private func applyFont() {
        label.font = .monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
        setNeedsLayout()
    }
}
