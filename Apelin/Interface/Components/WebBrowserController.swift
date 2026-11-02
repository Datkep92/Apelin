import UIKit
import WebKit

/// An in-app browser for http(s) links tapped in a chat. Keeps the reader
/// inside Apelin instead of handing the URL to Safari.
final class WebBrowserController: UIViewController {
    private let url: URL
    private let webView = WKWebView()
    private let progress = UIProgressView(progressViewStyle: .default)

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(url:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = url.host ?? url.absoluteString
        view.backgroundColor = .systemBackground

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.progress = 0
        view.addSubview(progress)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        webView.addObserver(self, forKeyPath: "estimatedProgress", options: .new, context: nil)
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "estimatedProgress" else { return }
        progress.progress = Float(webView.estimatedProgress)
        progress.isHidden = webView.estimatedProgress >= 1
    }

    deinit {
        webView.removeObserver(self, forKeyPath: "estimatedProgress")
    }
}

extension WebBrowserController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        progress.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        title = webView.title ?? url.host ?? url.absoluteString
        progress.progress = 1
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        progress.isHidden = true
        presentNotice(title: String(localized: "Unable to Load Page"), message: error.localizedDescription)
    }
}
