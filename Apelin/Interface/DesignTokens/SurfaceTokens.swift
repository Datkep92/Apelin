import UIKit

/// Shared surface metrics used by presentation-level polish.
enum SurfaceTokens {
    static let compactSpacing: CGFloat = 8
    static let cardCornerRadius: CGFloat = 16
    static let cardShadowOpacity: Float = 0.08
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowOffset = CGSize(width: 0, height: 3)
    static let sectionCornerRadius: CGFloat = 12
    static let sectionShadowOpacity: Float = 0.05
    static let sectionShadowRadius: CGFloat = 5
    static let sectionShadowOffset = CGSize(width: 0, height: 2)
    static let standardCornerRadius: CGFloat = 10
    static let gentleMotionDuration: TimeInterval = 0.22
}
