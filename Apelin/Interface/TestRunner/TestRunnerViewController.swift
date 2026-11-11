import ApelinCore
import ApelinProtocol
import UIKit

final class TestRunnerViewController: UIViewController {
    private let projectName: String
    private var scripts: [(name: String, command: String)] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyLabel = UILabel()

    init(projectName: String) {
        self.projectName = projectName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Test Runner")
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "script")
        view.addSubview(tableView)

        emptyLabel.text = String(localized: "No npm scripts found in package.json")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])

        loadScripts()
    }

    private func loadScripts() {
        guard let folder = DataFolder.app.project(named: projectName),
              let path = CanonicalPath.resolve(folder.path + "/package.json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scriptsObject = object["scripts"] as? [String: String]
        else {
            scripts = []
            tableView.reloadData()
            emptyLabel.isHidden = false
            return
        }

        scripts = scriptsObject
            .map { (name: $0.key, command: $0.value) }
            .sorted { $0.name < $1.name }
        tableView.reloadData()
        emptyLabel.isHidden = !scripts.isEmpty
    }
}

extension TestRunnerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        scripts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "script", for: indexPath)
        let script = scripts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = script.name
        content.secondaryText = script.command
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let script = scripts[indexPath.row]
        navigationController?.pushViewController(
            TerminalViewController(projectID: "project:\(projectName)", initialCommand: "npm run \(script.name)"),
            animated: true,
        )
    }
}
