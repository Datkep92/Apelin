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
        case signIn(String) // service name
        case signOut(String) // service name
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
            githubRows.append(.configure("GitHub"))
        } else {
            githubRows.append(.serviceStatus("GitHub", "Not configured"))
            githubRows.append(.configure("GitHub"))
        }
        sections.append((.github, githubRows))

        // Firebase
        var firebaseRows: [Row] = []
        if let fb = config.firebase, fb.projectID != nil {
            firebaseRows.append(.serviceStatus("Firebase", fb.projectID ?? "Linked"))
            firebaseRows.append(.configure("Firebase"))
        } else {
            firebaseRows.append(.serviceStatus("Firebase", "Not configured"))
            firebaseRows.append(.configure("Firebase"))
        }
        sections.append((.firebase, firebaseRows))

        // Cloudflare
        var cfRows: [Row] = []
        if let cf = config.cloudflare, cf.accountID != nil {
            cfRows.append(.serviceStatus("Cloudflare", cf.accountID ?? "Linked"))
            cfRows.append(.configure("Cloudflare"))
        } else {
            cfRows.append(.serviceStatus("Cloudflare", "Not configured"))
            cfRows.append(.configure("Cloudflare"))
        }
        sections.append((.cloudflare, cfRows))

        // Google Script
        var gsRows: [Row] = []
        if let gs = config.googleScript, gs.scriptID != nil {
            gsRows.append(.serviceStatus("Google Script", gs.scriptID ?? "Linked"))
            gsRows.append(.configure("Google Script"))
        } else {
            gsRows.append(.serviceStatus("Google Script", "Not configured"))
            gsRows.append(.configure("Google Script"))
        }
        sections.append((.googleScript, gsRows))

        // Telegram
        var tgRows: [Row] = []
        if let tg = config.telegram, tg.botToken != nil {
            tgRows.append(.serviceStatus("Telegram", tg.chatID ?? "Linked"))
            tgRows.append(.configure("Telegram"))
        } else {
            tgRows.append(.serviceStatus("Telegram", "Not configured"))
            tgRows.append(.configure("Telegram"))
        }
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
        default:
            return nil
        }
    }
}
