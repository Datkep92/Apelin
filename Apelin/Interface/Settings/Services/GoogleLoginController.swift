import ApelinProtocol
import SnapKit
import SPIndicator
import Then
import UIKit

/// Settings ▸ Services ▸ Google Sign-In: the device flow for Google OAuth 2.0,
/// shared by Firebase and Google Apps Script. The page shows Google's code,
/// copies it and opens Google's verification page; when the user approves,
/// the access token is returned via `onSignedIn`.
final class GoogleLoginController: UIViewController {
    var onSignedIn: ((String) -> Void)?

    private enum Step: Equatable {
        case starting
        case code(GoogleDeviceFlow.Code)
        case saving
        case failed(String)
    }

    private var step = Step.starting
    private var flow: Task<Void, Never>?
    private var openedCode: String?
    private var clientID: String
    private var scopes: [String]

    private lazy var browser = SignInBrowser(anchor: view)

    private let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
    private let iconView = UIImageView().then { $0.contentMode = .scaleAspectFit; $0.isAccessibilityElement = false }
    private let titleLabel = UILabel().then {
        $0.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        $0.adjustsFontForContentSizeCategory = true
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.accessibilityTraits = .header
    }
    private let subtitleLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
    }
    private let body = UIStackView().then { $0.axis = .vertical }
    private let primaryButton = UIButton(configuration: .filled()).then {
        $0.configuration?.cornerStyle = .large
        $0.configuration?.buttonSize = .large
        $0.configuration?.baseForegroundColor = AppAccent.foreground(glass: .white)
        $0.snp.makeConstraints { $0.height.greaterThanOrEqualTo(52) }
    }
    private let footnoteLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .footnote)
        $0.adjustsFontForContentSizeCategory = true
        $0.textColor = .secondaryLabel
        $0.textAlignment = .center
        $0.numberOfLines = 0
        $0.text = String(localized: "Google's page asks you to authorize Apelin. The token is kept only on this device.")
    }
    private lazy var spinnerItem: UIBarButtonItem = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "Waiting")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }()

    init(clientID: String, scopes: [String] = GoogleDeviceFlow.defaultScopes) {
        self.clientID = clientID
        self.scopes = scopes
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Google")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(clientID:scopes:)") }

    deinit { flow?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        primaryButton.addAction(UIAction { [weak self] _ in self?.primaryTapped() }, for: .primaryActionTriggered)
        let header = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel]).then {
            $0.axis = .vertical; $0.alignment = .center; $0.spacing = 10; $0.setCustomSpacing(18, after: iconView)
        }
        iconView.snp.makeConstraints { $0.size.equalTo(72) }
        titleLabel.snp.makeConstraints { $0.width.equalToSuperview() }
        subtitleLabel.snp.makeConstraints { $0.width.equalToSuperview() }
        let column = UIStackView(arrangedSubviews: [header, body, primaryButton, footnoteLabel]).then {
            $0.axis = .vertical; $0.spacing = 28; $0.setCustomSpacing(16, after: primaryButton)
        }
        view.addSubview(scrollView)
        scrollView.addSubview(column)
        scrollView.snp.makeConstraints { $0.edges.equalToSuperview() }
        column.snp.makeConstraints {
            $0.top.equalTo(scrollView.contentLayoutGuide).inset(40)
            $0.bottom.equalTo(scrollView.contentLayoutGuide).inset(32)
            $0.centerX.equalTo(scrollView.frameLayoutGuide)
            $0.width.lessThanOrEqualTo(420)
            $0.leading.greaterThanOrEqualTo(scrollView.frameLayoutGuide).inset(32)
            $0.trailing.lessThanOrEqualTo(scrollView.frameLayoutGuide).inset(32)
            $0.width.equalTo(scrollView.frameLayoutGuide).offset(-64).priority(.high)
        }
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if !context.isCancelled { self?.abandon() }
            }
        } else {
            abandon()
        }
    }

    private func abandon() {
        flow?.cancel()
        flow = nil
        browser.close()
    }

    private func start() {
        flow?.cancel()
        openedCode = nil
        show(.starting)
        flow = Task { [weak self] in
            guard let self else { return }
            let google = GoogleDeviceFlow.live(clientID: clientID)
            do {
                let code = try await google.requestCode(scopes: scopes)
                guard !Task.isCancelled else { return }
                self.show(.code(code))
                let token = try await google.token(for: code)
                guard !Task.isCancelled else { return }
                self.show(.saving)
                self.signedIn(token: token)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.show(.failed(Self.failureText(error)))
            }
        }
    }

    private func signedIn(token: String) {
        browser.close()
        SPIndicator.present(title: String(localized: "Signed In"), preset: .done, haptic: .success)
        onSignedIn?(token)
        if navigationController?.viewControllers.first === self {
            navigationController?.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    static func failureText(_ error: Error) -> String {
        switch error as? GoogleDeviceFlow.Failure {
        case .denied: return String(localized: "The sign-in was declined on Google.")
        case .expired: return String(localized: "The code expired before it was entered.")
        case let .refused(reason): return String(localized: "Google refused the sign-in: \(reason)")
        case .unreadable: return String(localized: "Google's answer could not be read.")
        case nil: return "Sign-in failed."
        }
    }

    private func primaryTapped() {
        switch step {
        case let .code(code): open(code)
        case .failed: start()
        case .starting, .saving: break
        }
    }

    private func open(_ code: GoogleDeviceFlow.Code) {
        UIPasteboard.general.string = code.userCode
        SPIndicator.present(title: String(localized: "Code Copied"), preset: .done, haptic: .success)
        browser.open(code.verificationURL)
    }

    private func show(_ next: Step) {
        step = next
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        iconView.image = UIImage(systemName: "globe")
        iconView.tintColor = .systemBlue
        titleLabel.text = String(localized: "Google")
        subtitleLabel.text = String(localized: "Enter this code on Google to sign in.")
        primaryButton.isHidden = true
        body.isHidden = true
        switch next {
        case .starting, .saving: break
        case let .code(code):
            body.isHidden = false
            body.addArrangedSubview(DeviceCodeView(code: code.userCode))
            primaryButton.isHidden = false
            primaryButton.configuration?.title = String(localized: "Open Google")
            if openedCode != code.deviceCode {
                openedCode = code.deviceCode
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, step == next, view.window != nil,
                          UIApplication.shared.applicationState == .active else { return }
                    open(code)
                }
            }
        case let .failed(message):
            browser.close()
            iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
            iconView.tintColor = .systemOrange
            titleLabel.text = String(localized: "Sign-In Failed")
            subtitleLabel.text = message
            primaryButton.isHidden = false
            primaryButton.configuration?.title = String(localized: "Try Again")
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Sign-In Failed"))
        }
        let waiting = if case .failed = next { false } else { true }
        navigationItem.rightBarButtonItem = waiting ? spinnerItem : nil
    }
}
