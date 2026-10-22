import UIKit

/// Previewable attachments share one aspect-aware album in either message role.
final class MessageImageGrid: UIView {
    var onPreview: ((ComposerAttachment) -> Void)?
    var maximumSize: CGSize = .zero {
        didSet {
            if maximumSize != oldValue {
                setNeedsLayout()
            }
        }
    }

    private var attachments: [ComposerAttachment] = []
    private var tiles: [UIButton] = []
    private var aspectRatios: [CGFloat] = []
    private let backgroundGradient = CAGradientLayer()
    private let content = UIView()
    private static let contentInset: CGFloat = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        backgroundGradient.startPoint = CGPoint(x: 0.6, y: 0)
        backgroundGradient.endPoint = CGPoint(x: 0.4, y: 1)
        layer.addSublayer(backgroundGradient)
        content.layer.cornerRadius = layer.cornerRadius - Self.contentInset
        content.layer.cornerCurve = .continuous
        content.clipsToBounds = true
        addSubview(content)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ images: [ComposerAttachment]) {
        guard images != attachments else { return }
        attachments = images
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        aspectRatios = []
        for attachment in images {
            let image = MessageAttachmentPreviews.shared.image(for: attachment)
            aspectRatios.append(image.map { $0.size.width / max($0.size.height, 1) } ?? 1)
            let tile = UIButton(type: .custom)
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            imageView.frame = tile.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tile.addSubview(imageView)
            tile.accessibilityLabel = attachment.name
            tile.accessibilityHint = String(localized: "Opens the attachment preview.")
            tile.addAction(UIAction { [weak self] _ in self?.onPreview?(attachment) }, for: .touchUpInside)
            content.addSubview(tile)
            tiles.append(tile)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundGradient.frame = bounds
        content.frame = CGRect(
            x: Self.contentInset,
            y: Self.contentInset,
            width: max(0, bounds.width - Self.contentInset * 2),
            height: max(0, bounds.height - Self.contentInset * 2),
        )
        let frames = Self.contentFrames(
            aspectRatios: aspectRatios,
            width: maximumSize.width,
            maximumHeight: maximumSize.height,
        )
        // the album reads from the leading edge: right to left, its first
        // image on the right
        for (tile, frame) in zip(tiles, frames) {
            tile.frame = content.directionalFrame(frame)
        }
    }

    static func size(for images: [ComposerAttachment], width: CGFloat, maximumHeight: CGFloat) -> CGSize {
        let ratios = images.map { attachment -> CGFloat in
            guard let image = MessageAttachmentPreviews.shared.image(for: attachment) else { return 1 }
            return image.size.width / max(image.size.height, 1)
        }
        let frames = contentFrames(aspectRatios: ratios, width: width, maximumHeight: maximumHeight)
        guard !frames.isEmpty else { return .zero }
        return CGSize(
            width: (frames.map(\.maxX).max() ?? 0) + contentInset * 2,
            height: (frames.map(\.maxY).max() ?? 0) + contentInset * 2,
        )
    }

    private static func contentFrames(aspectRatios: [CGFloat], width: CGFloat, maximumHeight: CGFloat) -> [CGRect] {
        MessageImageLayout.frames(
            aspectRatios: aspectRatios,
            width: max(0, min(540, width) - contentInset * 2),
            maximumHeight: max(0, maximumHeight - contentInset * 2),
        )
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateBackground()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBackground()
    }

    private func updateBackground() {
        let accent = tintColor.resolvedColor(with: traitCollection)
        backgroundGradient.colors = [accent.withAlphaComponent(0.10).cgColor, accent.withAlphaComponent(0.15).cgColor]
    }
}
