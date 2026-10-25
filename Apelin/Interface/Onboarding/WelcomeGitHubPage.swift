// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Table/action-bar layout copied from Irisin's WelcomeRepositoriesController.
import ApelinProtocol
import UIKit

/// The GitHub account, signed in with a code (`GitHubLoginController`), and
/// under it the package repository it publishes to, made or linked here as
/// Settings ▸ Git does (`DistributionRepositoryFlow`). Either can wait: Next
/// goes on without them.
final class WelcomeGitHubPage: WelcomeListPage {
    private enum Section: Hashable {
        case account
        case publishing
    }

    private enum Row: Hashable {
        case signIn(login: String?)
        case repository(String)
        case create(enabled: Bool)
        case link(enabled: Bool)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private lazy var repositories = DistributionRepositoryFlow(presenter: self) { [weak self] in self?.load() }
    private var login: String?
    private var loader: Task<Void, Never>?
    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "GitHub")
        next { [weak self] in self?.flow.showProject() }
        updateRows(linked: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            let settings = try? await ApelinService.app.gitSettings()
            let linked = try? await ApelinService.app.distributionRepositoryList(repositories: false).linked
            guard !Task.isCancelled, let self else { return }
            login = settings?.credentials.first { $0.host == GitHubDeviceFlow.host }?.username
            updateRows(linked: linked)
        }
    }

    private func updateRows(linked: DistributionRepository?) {
        let publishing: [Row] = linked.map { [.repository($0.fullName)] }
            ?? [.create(enabled: login != nil), .link(enabled: login != nil)]
        dataSource.update([(.account, [.signIn(login: login)]), (.publishing, publishing)])
    }

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.isAccessibilityElement = true
        switch row {
        case let .signIn(login):
            content.text = String(localized: "Sign In with GitHub")
            content.image = UIImage(named: "ProviderGitHubCopilot")
            content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
            content.secondaryText = login
            cell.accessoryType = login == nil ? .disclosureIndicator : .checkmark
            cell.accessibilityTraits = .button
            cell.accessibilityValue = login.map { String(localized: "Signed in as \($0)") }
        case let .repository(fullName):
            content.text = fullName
            cell.accessoryType = .checkmark
            cell.accessibilityValue = String(localized: "Linked")
        case let .create(enabled), let .link(enabled):
            if case .create = row {
                content.text = String(localized: "Create Distribution Repository…")
            } else {
                content.text = String(localized: "Link Distribution Repository…")
            }
            content.textProperties.color = enabled ? .label : .tertiaryLabel
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        return cell
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch dataSource.sectionIdentifier(for: section) {
        case .account?:
            text(.groupedFooter(), String(localized: "Sign in so agents can clone, pull and push your repositories on GitHub."))
        case .publishing?:
            text(.groupedHeader(), String(localized: "Publishing"))
        case nil:
            nil
        }
    }

    func tableView(_: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard dataSource.sectionIdentifier(for: section) == .publishing else { return nil }
        return text(
            .groupedFooter(),
            String(localized: "A package repository is an APT source on GitHub Pages that your release builds are published to. You can set it up later in Settings ▸ Git."),
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case .signIn?:
            guard presentedViewController == nil else { return }
            let page = GitHubLoginController()
            page.onSignedIn = { [weak self] _ in self?.load() }
            presentPageAsFormSheet(page)
        case .create(enabled: true)?:
            repositories.create()
        case .link(enabled: true)?:
            repositories.pick()
        default:
            break
        }
    }
}
