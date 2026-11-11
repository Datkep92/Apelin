import ApelinCore
import ApelinProtocol
import UIKit

final class GitStatusViewController: UIViewController {
    private let projectID: String
    private var entries: [GitStatusEntry] = []
    private var branch: String?
    private var head: String?

    private var stagedEntries: [GitStatusEntry] = []
    private var unstagedEntries: [GitStatusEntry] = []
    private var untrackedEntries: [GitStatusEntry] = []

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

        let stageAllButton = UIButton(type: .system)
        stageAllButton.setTitle(String(localized: "Stage all"), for: .normal)
        stageAllButton.addTarget(self, action: #selector(stageAll), for: .touchUpInside)
        stageAllButton.translatesAutoresizingMaskIntoConstraints = false

        let unstageAllButton = UIButton(type: .system)
        unstageAllButton.setTitle(String(localized: "Unstage all"), for: .normal)
        unstageAllButton.addTarget(self, action: #selector(unstageAll), for: .touchUpInside)
        unstageAllButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = UIStackView(arrangedSubviews: [stageAllButton, unstageAllButton, commitAllButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerLabel)
        view.addSubview(tableView)
        view.addSubview(commitField)
        view.addSubview(commitButton)
        view.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            commitField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            commitField.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            commitField.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -8),

            commitButton.centerYAnchor.constraint(equalTo: commitField.centerYAnchor),
            commitButton.widthAnchor.constraint(equalToConstant: 110),

            buttonRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: commitField.topAnchor, constant: -8),
            buttonRow.heightAnchor.constraint(equalToConstant: 32),
        ])

        // move buttonRow above tableView bottom? adjust: put buttonRow at bottom area already; ensure tableView bottom above buttonRow
        tableView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8).isActive = true

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
            groupEntries()
        } catch {
            headerLabel.text = "[Error: \(error.readableMessage)]"
            entries = []
            stagedEntries = []
            unstagedEntries = []
            untrackedEntries = []
        }
        tableView.reloadData()
        refreshControl.endRefreshing()
    }

    private func groupEntries() {
        stagedEntries = []
        unstagedEntries = []
        untrackedEntries = []
        for e in entries {
            if e.index == "?" && e.worktree == "?" {
                untrackedEntries.append(e)
            } else if e.index != " " && e.index != "?" {
                stagedEntries.append(e)
            }
            if e.worktree != " " && e.worktree != "?" {
                unstagedEntries.append(e)
            }
        }
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

    @objc private func stageAll() {
        let paths = unstagedEntries.map { $0.path } + untrackedEntries.map { $0.path }
        guard !paths.isEmpty else { return }
        Task {
            do {
                try await ApelinService.app.gitStage(projectID: projectID, paths: paths)
                await loadStatus()
            } catch {
                presentNotice(title: "Stage failed", message: error.readableMessage)
            }
        }
    }

    @objc private func unstageAll() {
        let paths = stagedEntries.map { $0.path }
        guard !paths.isEmpty else { return }
        Task {
            do {
                try await ApelinService.app.gitUnstage(projectID: projectID, paths: paths)
                await loadStatus()
            } catch {
                presentNotice(title: "Unstage failed", message: error.readableMessage)
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
    private func sectionEntries(_ section: Int) -> [GitStatusEntry] {
        switch section {
        case 0: return stagedEntries
        case 1: return unstagedEntries
        default: return untrackedEntries
        }
    }

    private func sectionTitle(_ section: Int) -> String? {
        switch section {
        case 0: return stagedEntries.isEmpty ? nil : String(localized: "Staged")
        case 1: return unstagedEntries.isEmpty ? nil : String(localized: "Changes")
        default: return untrackedEntries.isEmpty ? nil : String(localized: "Untracked")
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionTitle(section)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sectionEntries(section).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = entry.path
        content.secondaryText = "index: \(entry.index)  worktree: \(entry.worktree)"
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        let staged = (indexPath.section == 0)
        showDiff(for: entry, staged: staged)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let entry = sectionEntries(indexPath.section)[indexPath.row]
        if indexPath.section == 0 {
            let unstageAction = UIContextualAction(style: .normal, title: String(localized: "Unstage")) { [weak self] _, _, completion in
                self?.unstage(entry.path)
                completion(true)
            }
            unstageAction.backgroundColor = .systemOrange
            return UISwipeActionsConfiguration(actions: [unstageAction])
        } else {
            let stageAction = UIContextualAction(style: .normal, title: String(localized: "Stage")) { [weak self] _, _, completion in
                self?.stage(entry.path)
                completion(true)
            }
            stageAction.backgroundColor = .systemGreen
            return UISwipeActionsConfiguration(actions: [stageAction])
        }
    }
}
