import SnapKit
import UIKit

/// What a list shows in place of rows: a line of text, with a symbol above
/// it, or the symbol alone with the text left to VoiceOver. Fills whatever it is put in and centres the content, so it serves as
/// a table's `backgroundView` as is. Irisin's, with SF Symbols.
final class EmptyStateView: UIView {
    private let icon = UIImageView()
    private let caption = UILabel()

    init(symbolName: String, text: String, showsText: Bool = true) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        icon.image = UIImage(systemName: symbolName)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .light)
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        caption.font = .preferredFont(forTextStyle: .body)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.text = text
        caption.isHidden = !showsText
        // the line is the whole of it; the symbol above says the same again
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = text
        let stack = UIStackView(arrangedSubviews: [icon, caption])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        addSubview(stack)
        stack.snp.makeConstraints { x in
            x.center.equalToSuperview()
            x.width.lessThanOrEqualToSuperview().inset(32)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(symbolName:text:showsText:)")
    }
}
