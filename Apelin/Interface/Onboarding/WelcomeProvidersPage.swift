// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Table/action-bar layout copied from Irisin's WelcomeRepositoriesController.
import ApelinProtocol
import UIKit

final class WelcomeProvidersPage: WelcomeListPage {
    private let entries: [(String, AgentProvider)] = [
        (String(localized: "Claude Code"), .anthropicOAuth),
        (String(localized: "Codex"), .openAICodex),
        (String(localized: "Cursor"), .cursor),
        (String(localized: "GitHub Copilot"), .githubCopilot),
    ]
    private struct Row: Equatable {
        let provider: AgentProvider
        let name: String
        let connected: Bool
    }

    private lazy var dataSource = TableDataSource<Int, AgentProvider, Row>(
        tableView: tableView,
        identifier: { $0.provider },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private func updateRows() {
        dataSource.update([(0, entries.map { entry in
            Row(
                provider: entry.1,
                name: entry.0,
                connected: accounts.contains { $0.provider == entry.1 && $0.signedIn },
            )
        })])
    }

    private var accounts: [AgentAccount] = []
    private var loader: Task<Void, Never>?
    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add a Model Provider")
        next { [weak self] in self?.flow.showGitHub() }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func cell(for row: Row) -> UITableViewCell {
        let (name, provider) = (row.name, row.provider)
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = name
        content.image = provider.icon
        content.imageProperties.maximumSize = CGSize(width: 40, height: 40)
        cell.contentConfiguration = content
        // a signed-in account is ticked; tapping it still picks its models
        cell.accessoryType = row.connected ? .checkmark : .disclosureIndicator
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = name
        cell.accessibilityValue = row.connected
            ? String(localized: "Connected") : nil
        return cell
    }

    func tableView(_: UITableView, viewForHeaderInSection _: Int) -> UIView? {
        text(
            .groupedFooter(),
            String(localized: "Sign in to the account the agent uses to write, build and install your tweaks."),
        )
    }

    func tableView(_: UITableView, viewForFooterInSection _: Int) -> UIView? {
        text(.groupedFooter(), String(localized: "You can add more providers later in Settings."))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let provider = dataSource.value(at: indexPath)?.provider else { return }
        signIn(provider)
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let response = try await ApelinService.app.agentAccountList()
                guard !Task.isCancelled, let self else { return }
                accounts = response.accounts
                updateRows()
            } catch {}
        }
    }

    private func signIn(_ provider: AgentProvider) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let accounts = try await ApelinService.app.agentAccountList().accounts
                guard let account = accounts.first(where: { $0.provider == provider }) else {
                    throw ApelinError(
                        .unimplemented,
                        String(localized: "This provider is not available. You can add another provider in Settings."),
                    )
                }
                guard presentedViewController == nil, view.window != nil else { return }
                if account.signedIn {
                    presentPageAsFormSheet(ModelActivationController(account: account))
                } else {
                    let page = ProviderLoginController(account: account)
                    page.onFinish = { [weak self] in self?.load() }
                    presentPageAsFormSheet(page)
                }
            } catch { presentNotice(title: "Provider Unavailable", message: error.readableMessage) }
        }
    }
}
