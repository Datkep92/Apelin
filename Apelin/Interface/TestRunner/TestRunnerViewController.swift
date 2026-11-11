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

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .refresh,
            target: self,
            action: #selector(reload),
        )

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

        let runAll = UIButton(type: .system)
        runAll.setTitle(String(localized: "Run all tests"), for: .normal)
        runAll.addTarget(self, action: #selector(runAllTests), for: .touchUpInside)
        runAll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(runAll)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: runAll.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            runAll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            runAll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            runAll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            runAll.heightAnchor.constraint(equalToConstant: 44),
        ])

        loadScripts()
    }

    @objc private func reload() {
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
            .sorted { lhs, rhs in
                let lTest = lhs.name.lowercased().contains("test")
                let rTest = rhs.name.lowercased().contains("test")
                if lTest != rTest { return lTest && !rTest }
                return lhs.name < rhs.name
            }
        tableView.reloadData()
        emptyLabel.isHidden = !scripts.isEmpty
    }

    @objc private func runAllTests() {
        let testScript = scripts.first { $0.name.lowercased() == "test" }?.name
            ?? scripts.first { $0.name.lowercased().contains("test") }?.name
        let command = testScript.map { "npm run \($0)" } ?? "npm test"
        navigationController?.pushViewController(
            TerminalViewController(projectID: "project:\(projectName)", initialCommand: command),
            animated: true,
        )
    }
}

extension TestRunnerViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        scripts.isEmpty ? 0 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        scripts.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        scripts.contains(where: { $0.name.lowercased().contains("test") })
            ? String(localized: "Scripts")
            : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "script", for: indexPath)
        let script = scripts[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = script.name
        content.secondaryText = script.command
        content.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        if script.name.lowercased().contains("test") {
            content.image = UIImage(systemName: "checkmark.circle")
        }
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
