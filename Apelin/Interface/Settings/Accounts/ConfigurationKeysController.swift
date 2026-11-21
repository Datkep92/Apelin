import AlertController
import ApelinProtocol
import UIKit

/// Settings ▸ Model Providers ▸ one configuration: the keys saved at its Base
/// URL, and the way to add another. Everything here belongs to that one
/// address — its keys share the enabled models — so a new key needs only its
/// secret typed in. The name and the address are the group's, not a key's, so
/// renaming or removing them reaches every key at once.
final class ConfigurationKeysController: TableController {
    private enum Section: Hashable {
        case keys
        case action
    }

    private enum Row: Equatable {
        case key(AgentAccount)
        case addKey

        var id: String {
            switch self {
            case let .key(account): "key." + account.id
            case .addKey: "addKey"
            }
        }
    }

    private let configuration: ModelConfiguration
    /// The full listing, so the provider's own entry can say how a new key
    /// signs in and so the page refreshes after a key is added elsewhere.
    private var accounts: [AgentAccount]
    private let onChanged: () -> Void

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case let .key(account): return keyCell(account)
        case .addKey: return addKeyCell()
        }
    }

    /// The menu is read when it opens: the title it names follows a rename.
    private lazy var menuButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.configurationActions() ?? [])
            }]),
        )
        item.accessibilityLabel = String(localized: "\(configuration.title(keys: [])) Options")
        return item
    }()

    init(configuration: ModelConfiguration, accounts: [AgentAccount], onChanged: @escaping () -> Void) {
        self.configuration = configuration
        self.accounts = accounts
        self.onChanged = onChanged
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = menuButton
        dataSource.headerTitle = { section in
            switch section {
            case .keys: String(localized: "API Keys")
            case .action: nil
            }
        }
        dataSource.footerTitle = { section in
            guard case .action = section else { return nil }
            return String(localized: "Credentials stay in this device’s keychain.")
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    /// Keys of this group in the listing, in the order the model picker sees
    /// them, so the A/B letters here name the same keys everywhere.
    private var keys: [AgentAccount] {
        accounts.filter { $0.signedIn && ModelConfiguration.from($0) == configuration }
    }

    private func refresh() {
        Task { [weak self] in
            guard let list = try? await ApelinService.app.agentAccountList() else { return }
            self?.accounts = list.accounts
            self?.render()
        }
    }

    private func render() {
        title = configuration.title(keys: keys)
        menuButton.accessibilityLabel = String(localized: "\(configuration.title(keys: keys)) Options")
        let members = keys
        var listed: [(Section, [Row])] = []
        if !members.isEmpty {
            listed.append((.keys, members.map(Row.key)))
        }
        listed.append((.action, [.addKey]))
        dataSource.update(listed)
    }

    // MARK: - Table

    private func keyCell(_ account: AgentAccount) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        let name = configuration.title(keys: keys)
        content.text = ModelKeys.controlName(for: account, among: keys, title: { $0.name ?? name })
        content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: "key.fill")
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        cell.contentConfiguration = content
        cell.accessoryView = menuButton(account)
        cell.selectionStyle = .none
        return cell
    }

    private func addKeyCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Add Key")
        content.textProperties.color = .systemGreen
        content.image = UIImage(systemName: "plus.circle.fill")
        content.imageProperties.tintColor = .systemGreen
        cell.contentConfiguration = content
        cell.accessibilityLabel = String(localized: "Add Key")
        return cell
    }

    private func menuButton(_ account: AgentAccount) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.keyActions(account) ?? [])
        }])
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 44)
        let name = ModelKeys.controlName(for: account, among: keys, title: { $0.name ?? String(localized: "API Key") })
        button.accessibilityLabel = String(localized: "\(name) Options")
        return button
    }

    private func keyActions(_ account: AgentAccount) -> [UIMenuElement] {
        [
            UIAction(
                title: String(localized: "Edit"),
                image: UIImage(systemName: "pencil"),
            ) { [weak self] _ in
                self?.edit(account)
            },
            UIAction(
                title: String(localized: "Models"),
                image: UIImage(systemName: "checklist"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelActivationController(account: account))
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Sign Out"),
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.confirmSignOut(account)
                },
            ]),
        ]
    }

    private func configurationActions() -> [UIMenuElement] {
        [
            UIAction(
                title: String(localized: "Rename Configuration"),
                image: UIImage(systemName: "pencil.line"),
            ) { [weak self] _ in
                self?.renameConfiguration()
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Delete Configuration"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.confirmDeleteConfiguration()
                },
            ]),
        ]
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .addKey? = dataSource.value(at: indexPath) { return true }
        return false
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .key(account)? = dataSource.value(at: indexPath) else { return nil }
        let signOut = UIContextualAction(
            style: .destructive,
            title: String(localized: "Sign Out"),
        ) { [weak self] _, _, completion in
            self?.confirmSignOut(account)
            completion(false)
        }
        signOut.image = UIImage(systemName: "rectangle.portrait.and.arrow.right")
        return UISwipeActionsConfiguration(actions: [signOut])
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard case let .key(account)? = dataSource.value(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.keyActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if case .addKey? = dataSource.value(at: indexPath) { addKey() }
    }

    // MARK: - Acting

    /// A new key at the group's address: the id is fresh, the name and Base URL
    /// are already known, so the page hides the seeded address and asks only
    /// for the secret. The provider's own entry says how it signs in.
    private func addKey() {
        guard let id = AgentProfileID.make(for: configuration.provider),
              let listed = accounts.first(where: { $0.provider == configuration.provider })
        else { return }
        let account = configuration.newAccount(
            id: id,
            method: listed.method,
            alternativeMethods: listed.alternativeMethods,
        )
        let page = ProviderLoginController(
            account: account,
            seedValues: [AgentSignInField.baseURL.rawValue: configuration.baseURL],
        )
        page.onFinish = { [weak self] in
            self?.onChanged()
            self?.refresh()
        }
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    /// Editing a key already signed in reuses the secret the sign-in page
    /// loads for that id; there is nothing to seed by hand here.
    private func edit(_ account: AgentAccount) {
        let page = ProviderLoginController(account: account)
        page.onFinish = { [weak self] in
            self?.onChanged()
            self?.refresh()
        }
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    /// A rename is the group's, so it goes into the one record every key of
    /// the group reads its name from. No key is signed in again.
    private func renameConfiguration() {
        let alert = UIAlertController(
            title: String(localized: "Rename Configuration"),
            message: nil,
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.text = configuration.title(keys: keys)
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default) { [alert, weak self] _ in
            guard let self,
                  let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 120, !value.contains(where: \.isNewline)
            else { return }
            PendingConfigurations.save(value, baseURL: configuration.baseURL, for: configuration.storageID)
            onChanged()
            render()
        })
        present(alert, animated: true)
    }

    private func confirmSignOut(_ account: AgentAccount) {
        presentConfirmation(
            title: "Sign Out of \(account.title)?",
            message: "Agent sessions that use it stop working until you sign in again.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.signOut(account)
        }
    }

    private func signOut(_ account: AgentAccount) {
        Task { [weak self] in
            do {
                try await ApelinService.app.agentSignOut(provider: account.provider, profileID: account.profileID)
                EnabledModels.remove(for: account)
                self?.onChanged()
                self?.refresh()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }

    private func confirmDeleteConfiguration() {
        let name = configuration.title(keys: keys)
        presentConfirmation(
            title: "Delete \(name)?",
            message: "Every key saved at this address is removed from this device’s keychain. This cannot be undone.",
            confirmTitle: "Delete Configuration",
            destructive: true,
        ) { [weak self] in
            self?.deleteConfiguration()
        }
    }

    /// Deleting takes every key of the group and its name record. Signing out
    /// alone leaves the named configuration behind, waiting for a new key.
    private func deleteConfiguration() {
        let members = keys
        Task { [weak self] in
            guard let self else { return }
            do {
                for account in members {
                    try await ApelinService.app.agentSignOut(provider: account.provider, profileID: account.profileID)
                    EnabledModels.remove(for: account)
                }
                PendingConfigurations.remove(configuration.storageID)
                onChanged()
                navigationController?.popViewController(animated: true)
            } catch {
                presentNotice(title: "Unable to Delete Configuration", message: error.readableMessage)
            }
        }
    }
}
