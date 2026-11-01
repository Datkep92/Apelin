import UIKit
import WebKit

/// A per-chat HTML/JS playground: code editor on top, live preview below.
/// Content is stored per chat ID in UserDefaults so each conversation keeps
/// its own workspace.
final class HTMLPlaygroundController: UIViewController {
    private let chatID: UUID
    private let editor = UITextView()
    private let webView = WKWebView()
    private let runButton = UIButton(type: .system)
    private let storageKey: String

    init(chatID: UUID) {
        self.chatID = chatID
        self.storageKey = "htmlPlayground.\(chatID.uuidString)"
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(chatID:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "HTML Test")
        view.backgroundColor = .systemBackground

        editor.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.autocapitalizationType = .none
        editor.autocorrectionType = .no
        editor.smartDashesType = .no
        editor.smartQuotesType = .no
        editor.layer.borderColor = UIColor.separator.cgColor
        editor.layer.borderWidth = 0.5
        editor.layer.cornerRadius = 8
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        webView.layer.borderColor = UIColor.separator.cgColor
        webView.layer.borderWidth = 0.5
        webView.layer.cornerRadius = 8

        runButton.setTitle(String(localized: "Run"), for: .normal)
        runButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        runButton.backgroundColor = .systemBlue
        runButton.setTitleColor(.white, for: .normal)
        runButton.layer.cornerRadius = 8
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)

        let editorLabel = UILabel()
        editorLabel.text = String(localized: "Code")
        editorLabel.font = .preferredFont(forTextStyle: .caption1)
        editorLabel.textColor = .secondaryLabel

        let previewLabel = UILabel()
        previewLabel.text = String(localized: "Preview")
        previewLabel.font = .preferredFont(forTextStyle: .caption1)
        previewLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [editorLabel, editor, runButton, previewLabel, webView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            editor.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.45),
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            runButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        loadContent()
        webView.loadHTMLString(editor.text ?? "", baseURL: nil)
    }

    private func loadContent() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? defaultHTML
        editor.text = saved
    }

    private func saveContent() {
        UserDefaults.standard.set(editor.text, forKey: storageKey)
    }

    @objc private func runTapped() {
        saveContent()
        let html = editor.text ?? ""
        webView.loadHTMLString(html, baseURL: nil)
    }

    private var defaultHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        body { font-family: -apple-system, sans-serif; padding: 16px; }
        </style>
        </head>
        <body>
        <h1>Hello World</h1>
        <p>Edit code above and tap Run.</p>
        </body>
        </html>
        """
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveContent()
    }
}
