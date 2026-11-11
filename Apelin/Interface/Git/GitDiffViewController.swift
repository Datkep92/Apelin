import ApelinCore
import ApelinProtocol
import UIKit

final class GitDiffViewController: UIViewController {
    private let projectID: String
    private let path: String
    private let staged: Bool
    private let textView = UITextView()

    init(projectID: String, path: String, staged: Bool = false) {
        self.projectID = projectID
        self.path = path
        self.staged = staged
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = path
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        Task { await load() }
    }

    private func load() async {
        do {
            let response = try await ApelinService.app.gitDiff(projectID: projectID, path: path, staged: staged)
            let diff = response.diff.isEmpty ? String(localized: "No diff.") : response.diff
            let attributed = NSMutableAttributedString()
            let baseFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line) + "\n"
                let color: UIColor
                if line.hasPrefix("+++") || line.hasPrefix("---") {
                    color = .secondaryLabel
                } else if line.hasPrefix("+") {
                    color = .systemGreen
                } else if line.hasPrefix("-") {
                    color = .systemRed
                } else if line.hasPrefix("@@") {
                    color = .systemCyan
                } else {
                    color = .label
                }
                attributed.append(NSAttributedString(string: text, attributes: [
                    .font: baseFont,
                    .foregroundColor: color,
                ]))
            }
            textView.attributedText = attributed
        } catch {
            textView.text = "[Error: \(error.readableMessage)]"
        }
    }
}
