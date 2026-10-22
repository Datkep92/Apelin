// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// One of the composer's round icons: a symbol and a tap. It has no text,
/// so it carries the name VoiceOver reads, set with the symbol and changed
/// with it.
class ComposerIconButton: UIView {
    let imageView = UIImageView()

    var tapAction: () -> Void = {}

    required init() {
        super.init(frame: .zero)
        addSubview(imageView)
        imageView.tintColor = .label
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit

        let tap = UITapGestureRecognizer(target: self, action: #selector(buttonAction))
        addGestureRecognizer(tap)

        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(iconName:label:)")
    }

    required convenience init(iconName: String, label: String) {
        self.init()
        imageView.image = UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate)
        accessibilityLabel = label
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    /// Hidden or faded out, it is not there: the composer keeps its unused
    /// icons laid out but invisible.
    private var isShown: Bool {
        !isHidden && alpha > 0
    }

    @objc private func buttonAction() {
        guard isShown else { return }
        puddingAnimate()
        tapAction()
    }

    override func accessibilityActivate() -> Bool {
        guard isShown else { return false }
        tapAction()
        return true
    }

    func change(iconName: String) {
        UIView.transition(with: imageView, duration: 0.3, options: .transitionCrossDissolve) {
            self.imageView.image = UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate)
        }
    }
}
