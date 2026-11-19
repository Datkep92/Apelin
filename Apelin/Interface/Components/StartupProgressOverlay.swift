import UIKit

/// The startup progress overlay: a centered card with an activity indicator
/// and a line describing what is happening now. It replaces whatever was on
/// screen until all four startup steps finish.
final class StartupProgressOverlay: UIView {
    private let card = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let stepLabel = UILabel()
    private let stepsLabel = UILabel()
    private var step = 0
    private let stepNames = [
        String(localized: "Loading chats…"),
        String(localized: "Loading chats…"),
        String(localized: "Loading chats… Syncing…"),
        String(localized: "Loading chats… Syncing…"),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.35)

        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.25
        card.layer.shadowRadius = 20
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        addSubview(card)

        spinner.startAnimating()
        spinner.color = .label
        card.addSubview(spinner)

        stepLabel.font = .preferredFont(forTextStyle: .headline)
        stepLabel.textColor = .label
        stepLabel.textAlignment = .center
        stepLabel.text = stepNames[0]
        card.addSubview(stepLabel)

        stepsLabel.font = .preferredFont(forTextStyle: .caption1)
        stepsLabel.textColor = .secondaryLabel
        stepsLabel.textAlignment = .center
        stepsLabel.text = "1 / 4"
        card.addSubview(stepsLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        stepsLabel.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),

            stepLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stepLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
            stepLabel.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 20),
            stepLabel.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -20),

            stepsLabel.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stepsLabel.topAnchor.constraint(equalTo: stepLabel.bottomAnchor, constant: 6),
            stepsLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cardSize = CGSize(width: 240, height: 130)
        card.frame = CGRect(
            x: (bounds.width - cardSize.width) / 2,
            y: (bounds.height - cardSize.height) / 2,
            width: cardSize.width,
            height: cardSize.height,
        )
    }

    /// Advance to the next startup step. When `step` reaches 4 the overlay
    /// removes itself from its superview with a fade.
    func advance() {
        step += 1
        if step >= 4 {
            UIView.animate(withDuration: 0.25) {
                self.alpha = 0
            } completion: { _ in
                self.removeFromSuperview()
            }
            return
        }
        stepLabel.text = stepNames[step]
        stepsLabel.text = "\(min(step + 1, 4)) / 4"
    }
}
