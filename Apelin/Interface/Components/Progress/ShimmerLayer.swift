import UIKit

/// A mask that sweeps a bright band across text that is still loading. Its
/// resting alpha is half, so text drawn opaque under it reads at the 50% the
/// finished state uses. Size it to the text, not the view: a band sweeping a
/// wide, mostly empty view crosses the words for only a moment.
final class ShimmerLayer: CAGradientLayer {
    override init() {
        super.init()
        startPoint = CGPoint(x: 0, y: 0.5)
        endPoint = CGPoint(x: 1, y: 0.5)
        colors = [
            UIColor.white.withAlphaComponent(0.5).cgColor,
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.5).cgColor,
        ]
        locations = [0, 0, 0]
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// Starts the sweep again from the leading edge. The animation outlives
    /// a trip to the background, which would otherwise remove it.
    func start() {
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0]
        animation.toValue = [1, 1.2, 1.4]
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        add(animation, forKey: "shimmer")
    }

    func stop() {
        removeAllAnimations()
    }

    /// Covers the leading `width` points of `bounds`, without an implicit
    /// animation of the frame.
    func fit(width: CGFloat, in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = CGRect(x: bounds.minX, y: bounds.minY, width: min(bounds.width, ceil(width)), height: bounds.height)
        CATransaction.commit()
    }
}
