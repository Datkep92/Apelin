import UIKit
import WebKit

/// A per-chat HTML/JS playground: code editor on top, live preview below.
/// Content is stored per chat ID in UserDefaults so each conversation keeps
/// its own workspace. Also supports loading from clipboard and a shared file
/// that the AI agent can write to.
final class HTMLPlaygroundController: UIViewController {
    private let chatID: UUID
    private let editor = UITextView()
    private let webView = WKWebView()
    private let runButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let loadFileButton = UIButton(type: .system)
    private let storageKey: String
    private var userHasEdited = false

    /// Shared file path the AI agent can write HTML to for display.
    static let sharedFilePath = "/var/mobile/Documents/wiki.qaq.apelin/playground.html"

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
        editor.delegate = self
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

        configureButton(runButton, title: "Run", color: .systemBlue)
        runButton.addTarget(self, action: #selector(runTapped), for: .touchUpInside)

        configureButton(pasteButton, title: "Paste", color: .systemGreen)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)

        configureButton(loadFileButton, title: "Load AI", color: .systemOrange)
        loadFileButton.addTarget(self, action: #selector(loadFileTapped), for: .touchUpInside)

        let editorLabel = UILabel()
        editorLabel.text = String(localized: "Code")
        editorLabel.font = .preferredFont(forTextStyle: .caption1)
        editorLabel.textColor = .secondaryLabel

        let previewLabel = UILabel()
        previewLabel.text = String(localized: "Preview")
        previewLabel.font = .preferredFont(forTextStyle: .caption1)
        previewLabel.textColor = .secondaryLabel

        let buttonStack = UIStackView(arrangedSubviews: [runButton, pasteButton, loadFileButton])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 8
        buttonStack.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [editorLabel, editor, buttonStack, previewLabel, webView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            editor.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.4),
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            buttonStack.heightAnchor.constraint(equalToConstant: 44),
        ])

        loadContent()
        webView.loadHTMLString(editor.text ?? "", baseURL: nil)
        startFileWatch()
    }

    private func configureButton(_ button: UIButton, title: String, color: UIColor) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
    }

    private func loadContent() {
        let saved = UserDefaults.standard.string(forKey: storageKey) ?? defaultHTML
        editor.text = saved
        userHasEdited = false
    }

    private func saveContent() {
        UserDefaults.standard.set(editor.text, forKey: storageKey)
    }

    @objc private func runTapped() {
        saveContent()
        let html = editor.text ?? ""
        webView.loadHTMLString(html, baseURL: nil)
    }

    @objc private func pasteTapped() {
        if let text = UIPasteboard.general.string {
            editor.text = text
            userHasEdited = true
            saveContent()
            webView.loadHTMLString(text, baseURL: nil)
        }
    }

    @objc private func loadFileTapped() {
        let path = HTMLPlaygroundController.sharedFilePath
        do {
            let content = try String(contentsOfFile: path, encoding: .utf8)
            editor.text = content
            userHasEdited = false
            saveContent()
            webView.loadHTMLString(content, baseURL: nil)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "No AI content"),
                message: String(localized: "Could not read \(path): \(error.localizedDescription)"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private var fileWatchTimer: Timer?
    private var lastFileModification: Date?

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
        <p>Edit code above and tap Run. Or tap Paste / Load AI.</p>
        </body>
        </html>
        """
    }

    private func startFileWatch() {
        fileWatchTimer?.invalidate()
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkSharedFile()
        }
    }

    private func checkSharedFile() {
        let path = HTMLPlaygroundController.sharedFilePath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return }
        if modified != lastFileModification {
            lastFileModification = modified
            guard !userHasEdited else { return }
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                guard content != editor.text else { return }
                editor.text = content
                saveContent()
                webView.loadHTMLString(content, baseURL: nil)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        fileWatchTimer?.invalidate()
        fileWatchTimer = nil
        saveContent()
    }
}

extension HTMLPlaygroundController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        if textView === editor {
            userHasEdited = true
        }
    }
}
