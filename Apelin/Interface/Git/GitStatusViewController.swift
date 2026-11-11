import ApelinCore
import ApelinProtocol
import UIKit

final class GitStatusViewController: UIViewController {
    private let projectID: String
    private var entries: [GitStatusEntry] = []
    private var branch: String?
    private var head: String?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerLabel = UILabel()
    private let commitField = UITextField()
    private let commitButton = UIButton(type: .system)
    private let refreshControl = UIRefreshControl()

    init(projectName: String) {
        self.projectID = projectName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Git")
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = .systemBackground

        headerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        headerLabel.textColor = .secondaryLabel
        headerLabel.numberOfLines = 0
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)

        commitField.borderStyle = .roundedRect
        commitField.placeholder = String(localized: "Commit message")
        commitField.translatesAutoresizingMaskIntoConstraints = false

        commitButton.setTitle(String(localized: "Commit staged"), for: .normal)
        commitButton.addTarget(self, action: #selector(commitStaged), for: .touchUpInside)
        commitButton.translatesAutoresizingMaskIntoConstraints = false

        let commitAllButton = UIButton(type: .system)
        commitAllButton.setTitle(String(localized: "Commit all"), for: .normal)
        commitAllButton.addTarget(self, action: #selector(commitAll), for: .touchUpInside)
        commitAllButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(tableView)
        view.addSubview(commitField)
        view.addSubview(commitButton)
        view.addSubview(commitAllButton)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: commitField.topAnchor, constant: -8),

            commitField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            commitField.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            commitField.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -8),

            commitButton.centerYAnchor.constraint(equalTo: commitField.centerYAnchor),
            commitButton.widthAnchor.constraint(equalToConstant: 110),

            commitAllButton.topAnchor.constraint(equalTo: commitButton.bottomAnchor, constant: 4),
            commitAllButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
        ])

        Task { await loadStatus() }
    }

    @objc private func refresh() {
        Task { await loadStatus() }
    }

    private func loadStatus() async {
        do {
            let status = try await ApelinService.app.gitStatus(projectID: projectID)
            entries = status.entries
            branch = status.branch
            head = status.head
            headerLabel.text = "Branch: \(branch ?? "-")\nHEAD: \(head ?? "-")\nChanges: \(entries.count)"
        } catch {
            headerLabel.text = "[Error: \(error.readableMessage)]"
            entries = []
        }
        tableView.reloadData()
        refreshControl.endRefreshing()
    }

    @objc private func commitStaged() {
        guard let message = commitField.text, !message.isEmpty else { return }
        Task {
            do {
                let response = try await ApelinService.app.gitCommit(GitCommitRequest(projectID: projectID, message: message))
                commitField.text = ""
                presentNotice(title: "Committed", message: response.commitID)
                await loadStatus()
            } catch {
                presentNotice(title: "Commit failed", message: error.readableMessage)
            }
        }
    }

    @objc private func commitAll() {
        guard let message = commitField.text, !message.isEmpty else { return }
        Task {
            do {
                let response = try await ApelinService.app.gitCommit(GitCommitRequest(projectID: projectID, message: message, all: true))
                commitField.text = ""
                presentNotice(title: "Committed", message: response.commitID)
                await loadStatus()
            } catch {
                presentNotice(title: "Commit failed", message: error.readableMessage)
            }
        }
    }

    private func stage(_ path: String) {
        Task {
            do {
                try await ApelinService.app.gitStage(projectID: projectID, paths: [path])
                await loadStatus()
            } catch {
                presentNotice(title: "Stage failed", message: error.readableMessage)
            }
        }
    }

    private func unstage(_ path: String) {
        Task {
            do {
                try await ApelinService.app.gitUnstage(projectID: projectID, paths: [path])
                await loadStatus()
            } catch {
                presentNotice(title: "Unstage failed", message: error.readableMessage)
            }
        }
    }

    private func showDiff(for entry: GitStatusEntry, staged: Bool) {
        navigationController?.pushViewController(
            GitDiffViewController(projectID: projectID, path: entry.path, staged: staged),
            animated: true,
        )
    }
}

extension GitStatusViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.path
        content.secondaryText = "index: \(entry.index)  worktree: \(entry.worktree)"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        showDiff(for: entries[indexPath.row], staged: false)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = entries[indexPath.row]
        let stageAction = UIContextualAction(style: .normal, title: String(localized: "Stage")) { [weak self] _, _, completion in
            self?.stage(entry.path)
            completion(true)
        }
        stageAction.backgroundColor = .systemGreen
        let unstageAction = UIContextualAction(style: .normal, title: String(localized: "Unstage")) { [weak self] _, _, completion in
            self?.unstage(entry.path)
            completion(true)
        }
        unstageAction.backgroundColor = .systemOrange
        return UISwipeActionsConfiguration(actions: [stageAction, unstageAction])
    }
}
