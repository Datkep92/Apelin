import os
import UIKit
import WebKit

/// An in-app browser for http(s) and file links tapped in a conversation, in
/// a tool step's text, and for a page the reader asks to see whole. Keeps the
/// reader inside Apelin instead of handing the address to Safari, and says on
/// the page itself what went wrong rather than showing an empty one. While it
/// is open, the calls its pages make are recorded beside it, with the cookies
/// each one sent, so the same API can be called again outside the page.
final class WebBrowserController: UIViewController {
    private let url: URL
    private let webView: WKWebView
    private let progress = UIProgressView(progressViewStyle: .default)
    private let toolbar = UIStackView()

    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let reloadButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let safariButton = UIButton(type: .system)

    private let failureView = UIStackView()
    private let failureMessage = UILabel()
    private let log = Logger(subsystem: "wiki.qaq.apelin", category: "web")

    /// The web content process ended once already: a second time is a page
    /// this browser cannot render, not a hiccup.
    private var processEndedOnce = false

    init(url: URL) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        WebAPICaptureStore.shared.attach(to: configuration.userContentController)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(url:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = url.host ?? url.lastPathComponent
        view.backgroundColor = .systemBackground
        let callsButton = UIBarButtonItem(
            image: UIImage(systemName: "arrow.up.arrow.down"),
            primaryAction: UIAction { [weak self] _ in self?.showAPICalls() },
        )
        callsButton.accessibilityLabel = String(localized: "API Calls")
        navigationItem.rightBarButtonItem = callsButton

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progress = 0
        view.addSubview(progress)

        configureToolbar()
        configureFailureView()

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        updateToolbar()
        load(url)
    }

    deinit {
        webView.removeObserver(self, forKeyPath: "estimatedProgress")
    }

    override func observeValue(forKeyPath keyPath: String?, of _: Any?, change _: [NSKeyValueChangeKey: Any]?, context _: UnsafeMutableRawPointer?) {
        guard keyPath == "estimatedProgress" else { return }
        progress.progress = Float(webView.estimatedProgress)
        progress.isHidden = webView.estimatedProgress >= 1
    }

    // MARK: - The bar under the page

    private func configureToolbar() {
        toolbar.axis = .horizontal
        toolbar.distribution = .fillEqually
        toolbar.backgroundColor = .secondarySystemBackground
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let buttons = [backButton, forwardButton, reloadButton, shareButton, safariButton]
        let symbols = ["chevron.backward", "chevron.forward", "arrow.clockwise", "square.and.arrow.up", "safari"]
        let names = [
            String(localized: "Back"),
            String(localized: "Forward"),
            String(localized: "Reload"),
            String(localized: "Share"),
            String(localized: "Open in Safari"),
        ]
        let actions = [
            #selector(goBack),
            #selector(goForward),
            #selector(reloadPage),
            #selector(sharePage),
            #selector(openPageInSafari),
        ]
        for (index, button) in buttons.enumerated() {
            button.setImage(UIImage(systemName: symbols[index]), for: .normal)
            button.accessibilityLabel = names[index]
            button.addTarget(self, action: actions[index], for: .touchUpInside)
            toolbar.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 44),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func updateToolbar() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        safariButton.isEnabled = !(webView.url ?? url).isFileURL
    }

    // MARK: - What a page that would not load says

    private func configureFailureView() {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit

        let heading = UILabel()
        heading.text = String(localized: "Unable to Load Page")
        heading.font = .preferredFont(forTextStyle: .headline)
        heading.textAlignment = .center
        heading.numberOfLines = 0

        failureMessage.font = .preferredFont(forTextStyle: .subheadline)
        failureMessage.textColor = .secondaryLabel
        failureMessage.textAlignment = .center
        failureMessage.numberOfLines = 0

        let retry = UIButton(type: .system)
        retry.setTitle(String(localized: "Retry"), for: .normal)
        retry.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        retry.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)

        let safari = UIButton(type: .system)
        safari.setTitle(String(localized: "Open in Safari"), for: .normal)
        safari.addTarget(self, action: #selector(openPageInSafari), for: .touchUpInside)

        failureView.axis = .vertical
        failureView.alignment = .center
        failureView.spacing = 12
        failureView.isHidden = true
        failureView.translatesAutoresizingMaskIntoConstraints = false
        for item in [icon, heading, failureMessage, retry, safari] {
            failureView.addArrangedSubview(item)
        }
        view.addSubview(failureView)

        NSLayoutConstraint.activate([
            icon.heightAnchor.constraint(equalToConstant: 34),
            failureView.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            failureView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            failureView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
    }

    private func load(_ url: URL) {
        failureView.isHidden = true
        progress.isHidden = false
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    private func report(_ error: Error) {
        let failure = error as NSError
        // A page a tap or a redirect replaced is not a failure.
        guard failure.code != NSURLErrorCancelled else { return }
        log.error("page failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        showFailure(message: error.localizedDescription)
    }

    private func showFailure(message: String?) {
        progress.isHidden = true
        failureMessage.text = message
        failureView.isHidden = false
        updateToolbar()
    }

    @objc private func goBack() {
        webView.goBack()
        updateToolbar()
    }

    @objc private func goForward() {
        webView.goForward()
        updateToolbar()
    }

    @objc private func reloadPage() {
        if webView.url == nil {
            load(url)
        } else {
            failureView.isHidden = true
            webView.reload()
        }
    }

    @objc private func sharePage() {
        let page = webView.url ?? url
        let activity = UIActivityViewController(activityItems: [page], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
    }

    @objc private func openPageInSafari() {
        let page = webView.url ?? url
        guard !page.isFileURL else { return }
        UIApplication.shared.open(page)
    }

    /// The API calls the pages here made: what a site's own interface asked its
    /// server, with the cookies each call sent, so the same API can be called
    /// again outside the page.
    @objc private func showAPICalls() {
        let calls = WebAPICallsController()
        if let navigation = navigationController {
            navigation.pushViewController(calls, animated: true)
        } else {
            presentPageAsFormSheet(calls)
        }
    }
}

extension WebBrowserController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = target.scheme?.lowercased() ?? ""
        guard !["http", "https", "file", "about", "data", "blob"].contains(scheme) else {
            // A link that asks for a window of its own (`target="_blank"`)
            // opens here rather than nowhere.
            if navigationAction.targetFrame == nil, navigationAction.navigationType == .linkActivated {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        if scheme == "apelin" {
            // Apelin's own link: it opens a conversation in place.
            _ = ApelinLinkRouter.open(target, in: view.window?.windowScene)
        } else {
            UIApplication.shared.open(target)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        failureView.isHidden = true
        progress.progress = 0
        progress.isHidden = false
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        updateToolbar()
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        title = webView.title ?? url.host ?? url.lastPathComponent
        progress.progress = 1
        progress.isHidden = true
        failureView.isHidden = true
        updateToolbar()
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !processEndedOnce else {
            log.error("web content process ended twice; the page cannot be drawn")
            showFailure(message: nil)
            return
        }
        processEndedOnce = true
        log.error("web content process ended; loading the page again")
        load(webView.url ?? url)
    }
}
