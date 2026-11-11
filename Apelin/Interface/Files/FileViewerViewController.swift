import ApelinCore
import UIKit

final class FileViewerViewController: UIViewController {
    private let projectName: String
    private let relativePath: String
    private let textView = UITextView()

    init(projectName: String, relativePath: String) {
        self.projectName = projectName
        self.relativePath = relativePath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = (relativePath as NSString).lastPathComponent
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

        loadContent()
    }

    private func loadContent() {
        guard let folder = DataFolder.app.project(named: projectName),
              let root = CanonicalPath.resolve(folder.path),
              let full = CanonicalPath.resolve(root + "/" + relativePath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: full))
        else {
            textView.text = String(localized: "Unable to read file.")
            return
        }
        if let text = String(data: data, encoding: .utf8) {
            textView.text = text
        } else {
            textView.text = String(format: String(localized: "Binary file (%d bytes)."), data.count)
        }
    }
}
