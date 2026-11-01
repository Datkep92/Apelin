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
        case serviceStatus(String, String)
        case configure(String)
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
            let name = fb.projectID ?? "Linked"
            firebaseRows.append(.serviceStatus("Firebase", name))
        } else if config.firebase?.accessToken != nil {
            firebaseRows.append(.serviceStatus("Firebase", "Signed in"))
        } else {
            firebaseRows.append(.serviceStatus("Firebase", "Not configured"))
        }
        firebaseRows.append(.configure("Firebase"))
        sections.append((.firebase, firebaseRows))

        // Cloudflare
        var cfRows: [Row] = []
        if let cf = config.cloudflare, cf.accountID != nil {
            cfRows.append(.serviceStatus("Cloudflare", cf.accountID ?? "Linked"))
        } else if config.cloudflare?.apiToken != nil {
            cfRows.append(.serviceStatus("Cloudflare", "Token saved"))
        } else {
            cfRows.append(.serviceStatus("Cloudflare", "Not configured"))
        }
        cfRows.append(.configure("Cloudflare"))
        sections.append((.cloudflare, cfRows))

        // Google Script
        var gsRows: [Row] = []
        if let gs = config.googleScript, gs.scriptID != nil {
            gsRows.append(.serviceStatus("Google Script", gs.scriptID ?? "Linked"))
        } else if config.googleScript?.accessToken != nil {
            gsRows.append(.serviceStatus("Google Script", "Signed in"))
        } else {
            gsRows.append(.serviceStatus("Google Script", "Not configured"))
        }
        gsRows.append(.configure("Google Script"))
        sections.append((.googleScript, gsRows))

        // Telegram
        var tgRows: [Row] = []
        if let tg = config.telegram, tg.botToken != nil {
            let name = tg.botUsername ?? tg.chatID ?? "Linked"
            tgRows.append(.serviceStatus("Telegram", name))
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
            try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
            self.updateRows()
            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
        })
        present(alert, animated: true)
    }

    // MARK: - Firebase

    private func presentFirebaseConfig() {
        // Ask for Google Client ID first
        let alert = UIAlertController(
            title: "Firebase Configuration",
            message: "Enter your Google OAuth Client ID for Firebase (from Google Cloud Console).",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Google Client ID"
            field.text = self.config.firebase?.googleClientID
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign In with Google", style: .default) { [weak self] _ in
            guard let self, let clientID = alert.textFields?.first?.text, !clientID.isEmpty else { return }
            self.runGoogleSignIn(clientID: clientID, service: "Firebase") { [weak self] token in
                guard let self else { return }
                self.config.firebase = FirebaseServiceConfig(
                    projectID: self.config.firebase?.projectID,
                    accessToken: token,
                    googleClientID: clientID,
                )
                try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                self.updateRows()
                self.presentFirebaseProjectPicker(accessToken: token)
            }
        })
        present(alert, animated: true)
    }

    private func presentFirebaseProjectPicker(accessToken: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = FirebaseServiceClient(accessToken: accessToken)
                let projects = try await client.listProjects()
                guard !projects.isEmpty else {
                    SPIndicator.present(title: "No projects found", preset: .error, haptic: .error)
                    return
                }
                await MainActor.run {
                    let alert = UIAlertController(title: "Select Firebase Project", message: nil, preferredStyle: .actionSheet)
                    for project in projects {
                        alert.addAction(UIAlertAction(title: project.displayName ?? project.id, style: .default) { [weak self] _ in
                            guard let self else { return }
                            self.config.firebase?.projectID = project.id
                            try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                            self.updateRows()
                            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
                        })
                    }
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    SPIndicator.present(title: "Failed to load projects", message: error.localizedDescription, preset: .error, haptic: .error)
                }
            }
        }
    }

    // MARK: - Cloudflare

    private func presentCloudflareConfig() {
        let alert = UIAlertController(
            title: "Cloudflare Configuration",
            message: "Enter your Cloudflare API token.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "API Token"
            field.text = self.config.cloudflare?.apiToken
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self, let token = alert.textFields?.first?.text, !token.isEmpty else { return }
            self.validateCloudflareToken(token)
        })
        present(alert, animated: true)
    }

    private func validateCloudflareToken(_ token: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = CloudflareServiceClient(apiToken: token)
                _ = try await client.validateToken()
                let accounts = try await client.listAccounts()
                await MainActor.run {
                    self.config.cloudflare = CloudflareServiceConfig(apiToken: token)
                    try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                    self.updateRows()
                    if accounts.count == 1 {
                        self.config.cloudflare?.accountID = accounts[0].id
                        try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                        self.updateRows()
                        SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
                    } else if accounts.count > 1 {
                        let alert = UIAlertController(title: "Select Account", message: nil, preferredStyle: .actionSheet)
                        for account in accounts {
                            alert.addAction(UIAlertAction(title: account.name ?? account.id, style: .default) { [weak self] _ in
                                guard let self else { return }
                                self.config.cloudflare?.accountID = account.id
                                try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                                self.updateRows()
                                SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
                            })
                        }
                        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                        self.present(alert, animated: true)
                    } else {
                        SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
                    }
                }
            } catch {
                await MainActor.run {
                    SPIndicator.present(title: "Invalid token", message: error.localizedDescription, preset: .error, haptic: .error)
                }
            }
        }
    }

    // MARK: - Google Script

    private func presentGoogleScriptConfig() {
        let alert = UIAlertController(
            title: "Google Script Configuration",
            message: "Enter your Google OAuth Client ID for Apps Script (from Google Cloud Console).",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Google Client ID"
            field.text = self.config.googleScript?.googleClientID
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign In with Google", style: .default) { [weak self] _ in
            guard let self, let clientID = alert.textFields?.first?.text, !clientID.isEmpty else { return }
            self.runGoogleSignIn(clientID: clientID, service: "Google Script") { [weak self] token in
                guard let self else { return }
                self.config.googleScript = GoogleScriptServiceConfig(
                    scriptID: self.config.googleScript?.scriptID,
                    accessToken: token,
                    googleClientID: clientID,
                )
                try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                self.updateRows()
                self.presentGoogleScriptProjectPicker(accessToken: token)
            }
        })
        present(alert, animated: true)
    }

    private func presentGoogleScriptProjectPicker(accessToken: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = GoogleScriptServiceClient(accessToken: accessToken)
                let projects = try await client.listProjects()
                guard !projects.isEmpty else {
                    SPIndicator.present(title: "No projects found", preset: .error, haptic: .error)
                    return
                }
                await MainActor.run {
                    let alert = UIAlertController(title: "Select Script Project", message: nil, preferredStyle: .actionSheet)
                    for project in projects {
                        alert.addAction(UIAlertAction(title: project.title ?? project.id, style: .default) { [weak self] _ in
                            guard let self else { return }
                            self.config.googleScript?.scriptID = project.id
                            try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                            self.updateRows()
                            SPIndicator.present(title: "Saved", preset: .done, haptic: .success)
                        })
                    }
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    SPIndicator.present(title: "Failed to load projects", message: error.localizedDescription, preset: .error, haptic: .error)
                }
            }
        }
    }

    // MARK: - Telegram

    private func presentTelegramConfig() {
        let alert = UIAlertController(
            title: "Telegram Configuration",
            message: "Enter the Telegram bot token.",
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = "Bot Token"
            field.text = self.config.telegram?.botToken
        }
        alert.addTextField { field in
            field.placeholder = "Chat ID (optional)"
            field.text = self.config.telegram?.chatID
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in
            guard let self else { return }
            let botToken = alert.textFields?[0].text
            let chatID = alert.textFields?[1].text
            guard let token = botToken, !token.isEmpty else { return }
            self.validateTelegramToken(token, chatID: chatID)
        })
        present(alert, animated: true)
    }

    private func validateTelegramToken(_ token: String, chatID: String?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = TelegramServiceClient(botToken: token)
                let botInfo = try await client.getMe()
                await MainActor.run {
                    self.config.telegram = TelegramServiceConfig(
                        botToken: token,
                        chatID: chatID?.isEmpty == true ? nil : chatID,
                        botUsername: botInfo.username,
                    )
                    try? ProjectServiceConfigStore.save(self.config, projectName: self.projectName)
                    self.updateRows()
                    SPIndicator.present(title: "Saved", message: botInfo.username ?? "Bot validated", preset: .done, haptic: .success)
                }
            } catch {
                await MainActor.run {
                    SPIndicator.present(title: "Invalid bot token", message: error.localizedDescription, preset: .error, haptic: .error)
                }
            }
        }
    }

    // MARK: - Google Sign-In Helper

    private func runGoogleSignIn(clientID: String, service: String, completion: @escaping (String) -> Void) {
        let controller = GoogleLoginController(clientID: clientID)
        controller.onSignedIn = { token in
            completion(token)
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}
