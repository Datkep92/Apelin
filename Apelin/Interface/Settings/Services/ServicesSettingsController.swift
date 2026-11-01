import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Services: per-project configuration for GitHub, Firebase,
/// Cloudflare, Google Script and Telegram. Each project stores its own
/// configuration so that multiple projects do not share one account or
/// repository.
final class ServicesSettingsController: TableController {
    private enum Section: Hashable {
        case project
        case github
        case firebase
        case cloudflare
        case googleScript
        case telegram
    }

    private enum Row: Hashable {
        case projectName(String)
        case serviceStatus(String, String) // (service name, status text)
        case configure(String) // service name
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private var projectName: String
    private var config: ProjectServiceConfig

    init(projectName: String) {
        self.projectName = projectName
        self.config = ProjectServiceConfigStore.load(projectName: projectName)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Services")
        navigationItem.backButtonDisplayMode = .minimal
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        updateRows()
    }

    private func updateRows() {
        var sections: [(Section, [Row])] = [
            (.project, [.projectName(projectName)]),
        ]

        // GitHub
        var githubRows: [Row] = []
        if let gh = config.github, gh.repositoryFullName != nil {
            githubRows.append(.serviceStatus("GitHub", gh.repositoryFullName ?? "Linked"))
        } else {
            githubRows.append(.serviceStatus("GitHub", "Not configured"))
        }
        githubRows.append(.configure("GitHub"))
        sections.append((.github, githubRows))

        // Firebase
        var firebaseRows: [Row] = []
        if let fb = config.firebase, fb.projectID != nil {
            firebaseRows.append(.serviceStatus("Firebase", fb.projectID ?? "Linked"))
        } else {
            firebaseRows.append(.serviceStatus("Firebase", "Not configured"))
        }
        firebaseRows.append(.configure("Firebase"))
        sections.append((.firebase, firebaseRows))

        // Cloudflare
        var cfRows: [Row] = []
        if let cf = config.cloudflare, cf.accountID != nil {
            cfRows.append(.serviceStatus("Cloudflare", cf.accountID ?? "Linked"))
        } else {
            cfRows.append(.serviceStatus("Cloudflare", "Not configured"))
        }
        cfRows.append(.configure("Cloudflare"))
        sections.append((.cloudflare, cfRows))

        // Google Script
        var gsRows: [Row] = []
        if let gs = config.googleScript, gs.scriptID != nil {
            gsRows.append(.serviceStatus("Google Script", gs.scriptID ?? "Linked"))
        } else {
            gsRows.append(.serviceStatus("Google Script", "Not configured"))
        }
        gsRows.append(.configure("Google Script"))
        sections.append((.googleScript, gsRows))

        // Telegram
        var tgRows: [Row] = []
        if let tg = config.telegram, tg.botToken != nil {
            tgRows.append(.serviceStatus("Telegram", tg.chatID ?? "Linked"))
        } else {
            tgRows.append(.serviceStatus("Telegram", "Not configured"))
        }
        tgRows.append(.configure("Telegram"))
        sections.append((.telegram, tgRows))

        dataSource.update(sections)
    }

    private func cell(for row: Row) -> UITableViewCell? {
        switch row {
        case let .projectName(name):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Project")
            content.secondaryText = name
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .serviceStatus(service, status):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = service
            content.secondaryText = status
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .configure(service):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Configure \(service)…")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return false }
        if case .configure = row { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .configure(service)? = dataSource.value(at: indexPath) else { return }
        presentConfigure(service: service)
    }

    private func presentConfigure(service: String) {
        switch service {
        case "GitHub":
            presentGitHubConfig()
        case "Firebase":
            presentFirebaseConfig()
        case "Cloudflare":
            presentCloudflareConfig()
        case "Google Script":
            presentGoogleScriptConfig()
        case "Telegram":
            presentTelegramConfig()
        default:
            break
        }
    }

    // MARK: - GitHub

    private func presentGitHubConfig() {
        let alert = UIAlertController(
            title: "GitHub Configuration",
            message: "Enter the repository full name for this project (e.g. owner/repo).",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "owner/repo"
            field.text = self.config.github?.repositoryFullName
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self, let text = alert.textFields?.first?.text, !text.isEmpty else { return }
            self.config.github = GitHubServiceConfig(repositoryFullName: text)
            ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }

    // MARK: - Firebase

    private func presentFirebaseConfig() {
        let alert = UIAlertController(
            title: "Firebase Configuration",
            message: "Enter the Firebase project ID for this project.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Firebase Project ID"
            field.text = self.config.firebase?.projectID
        }
        alert.addTextField { field in
            field.placeholder = "API Key (optional)"
            field.text = self.config.firebase?.apiKey
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let projectID = alert.textFields?[0].text
            let apiKey = alert.textFields?[1].text
            self.config.firebase = FirebaseServiceConfig(
                projectID: projectID?.isEmpty == true ? nil : projectID,
                apiKey: apiKey?.isEmpty == true ? nil : apiKey,
            )
            ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }

    // MARK: - Cloudflare

    private func presentCloudflareConfig() {
        let alert = UIAlertController(
            title: "Cloudflare Configuration",
            message: "Enter the Cloudflare account ID and zone ID for this project.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Account ID"
            field.text = self.config.cloudflare?.accountID
        }
        alert.addTextField { field in
            field.placeholder = "Zone ID (optional)"
            field.text = self.config.cloudflare?.zoneID
        }
        alert.addTextField { field in
            field.placeholder = "API Token (optional)"
            field.text = self.config.cloudflare?.apiToken
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let accountID = alert.textFields?[0].text
            let zoneID = alert.textFields?[1].text
            let apiToken = alert.textFields?[2].text
            self.config.cloudflare = CloudflareServiceConfig(
                accountID: accountID?.isEmpty == true ? nil : accountID,
                zoneID: zoneID?.isEmpty == true ? nil : zoneID,
                apiToken: apiToken?.isEmpty == true ? nil : apiToken,
            )
            ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }

    // MARK: - Google Script

    private func presentGoogleScriptConfig() {
        let alert = UIAlertController(
            title: "Google Script Configuration",
            message: "Enter the Google Apps Script ID for this project.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Script ID"
            field.text = self.config.googleScript?.scriptID
        }
        alert.addTextField { field in
            field.placeholder = "Web App URL (optional)"
            field.text = self.config.googleScript?.webAppURL
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let scriptID = alert.textFields?[0].text
            let webAppURL = alert.textFields?[1].text
            self.config.googleScript = GoogleScriptServiceConfig(
                scriptID: scriptID?.isEmpty == true ? nil : scriptID,
                webAppURL: webAppURL?.isEmpty == true ? nil : webAppURL,
            )
            ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }

    // MARK: - Telegram

    private func presentTelegramConfig() {
        let alert = UIAlertController(
            title: "Telegram Configuration",
            message: "Enter the Telegram bot token and chat ID for this project.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Bot Token"
            field.text = self.config.telegram?.botToken
        }
        alert.addTextField { field in
            field.placeholder = "Chat ID"
            field.text = self.config.telegram?.chatID
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let botToken = alert.textFields?[0].text
            let chatID = alert.textFields?[1].text
            self.config.telegram = TelegramServiceConfig(
                botToken: botToken?.isEmpty == true ? nil : botToken,
                chatID: chatID?.isEmpty == true ? nil : chatID,
            )
            ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }
}
