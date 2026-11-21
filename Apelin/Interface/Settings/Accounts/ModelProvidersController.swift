import AlertController
import ApelinProtocol
import Then
import UIKit

/// Settings ▸ Model Providers: every provider apelin-agent can sign in to,
/// in the order it lists them (kwwk's). Named configurations — a name and a
/// Base URL — come first, one row each; opening one lists its keys and adds
/// more at the same address. Then the providers that keep a single sign-in:
/// signed-in ones first, each with who it is signed in as under its name and a
/// `...` menu (Edit Configuration or Sign In Again, Sign Out); then the rest,
/// those signed in to with an account apart from those that take a typed key.
/// A configuration keeps its name and its empty row after its last key is
/// signed out; only deleting it from its detail page takes it off the list.
/// A search field narrows the list by name, address or provider, and `+` adds a
/// configuration with a name and an address — the keys come afterwards.
final class ModelProvidersController: TableController, UISearchResultsUpdating {
    private enum Group: Hashable {
        case signedIn
        case accounts
        case keys
        /// The one preference of this screen, below every key it applies to.
        case fallback

        var title: String {
            switch self {
            case .signedIn: String(localized: "Signed In")
            case .accounts: String(localized: "Sign In with an Account")
            case .keys: String(localized: "API Keys")
            case .fallback: String(localized: "When a Model Fails")
            }
        }
    }

    private enum Status: Equatable {
        case loading
        case unavailable(String)
        case noResults
    }

    private enum Section: Hashable {
        /// One row per named Base URL, opening a page of its keys.
        case configurations
        case group(Group)
        case status
    }

    private enum Row: Equatable {
        case configuration(ModelConfiguration)
        case account(AgentAccount)
        /// Whether a run out of keys for its model may try another model.
        case fallback
        case status(Status)
        var id: String {
            switch self {
            case let .configuration(configuration): configuration.storageID
            case let .account(account): account.id
            case .fallback: "fallback"
            case .status: "status"
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case let .configuration(configuration): return configurationCell(configuration)
        case let .account(account): return accountCell(account)
        case .fallback: return fallbackCell()
        case let .status(status): return statusCell(status)
        }
    }

    /// The accounts as apelin-agent last listed them.
    private var accounts: [AgentAccount] = []
    private var loaded = false
    private var failure: Error?
    private var query = ""
    private var sections: [(Section, [Row])] = [(.status, [.status(.loading)])]
    private var loader: Task<Void, Never>?
    private let search = UISearchController(searchResultsController: nil)

    /// `+` adds another configuration of a provider that keeps several; the
    /// menu is read each time it opens, in kwwk's order. A provider's own
    /// sign-in is the row below, so this never has to come first.
    private lazy var addButton: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.addActions() ?? [])
            }]),
        )
        item.preferredMenuElementOrder = .fixed
        item.accessibilityLabel = String(localized: "Add Configuration")
        item.isEnabled = false
        return item
    }()

    /// The providers that keep several configurations, in kwwk's order.
    private var addableProviders: [AgentProvider] {
        var seen = Set<AgentProvider>()
        return accounts.map(\.provider).filter { provider in
            AgentProfileID.canonicalID(for: provider) != nil && seen.insert(provider).inserted
        }
    }

    /// One action per such provider, titled by the provider itself.
    private func addActions() -> [UIMenuElement] {
        addableProviders.map { provider in
            UIAction(title: provider.displayName, image: provider.icon) { [weak self] _ in
                self?.addConfiguration(provider: provider)
            }
        }
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Providers")
        navigationItem.backButtonDisplayMode = .minimal
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = addButton
        definesPresentationContext = true
        dataSource.headerTitle = { section in
            switch section {
            case .configurations: String(localized: "Configurations")
            case let .group(group): group.title
            case .status: nil
            }
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, !isStatus(section), !isPreference(section),
                  section == sections.last(where: { !self.isPreference($0.0) })?.0
            else { return nil }
            return String(localized: "Credentials stay in this device’s keychain.")
        }
        dataSource.update(sections)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let list = try await ApelinService.app.agentAccountList()
                guard !Task.isCancelled, let self else { return }
                // The name and address of a group are kept by this screen:
                // a credential merely names its own key now.
                PendingConfigurations.prune(listed: Set(list.accounts.map(\.id)))
                accounts = list.accounts
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            loaded = true
            regroup()
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        regroup()
    }

    private func regroup() {
        if !loaded {
            sections = [(.status, [.status(.loading)])]
        } else if let failure, accounts.isEmpty {
            sections = [(.status, [.status(.unavailable(ProviderLoginController.unavailableText(failure)))])]
        } else {
            // One row per named Base URL, then the providers that keep a
            // single sign-in. A configuration is listed even with no keys.
            let configurationRows = allConfigurations()
                .filter(matches)
                .sorted {
                    if $0.provider.rawValue != $1.provider.rawValue { return $0.provider.rawValue < $1.provider.rawValue }
                    return $0.baseURL < $1.baseURL
                }
                .map(Row.configuration)
            let rest = accounts.filter { ModelConfiguration.from($0) == nil } + legacyWaiting(in: accounts)
            let shown = rest.filter(matches)
            let groups: [(Group, [AgentAccount])] = [
                (.signedIn, shown.filter(\.signedIn)),
                (.accounts, shown.filter { !$0.signedIn && $0.method != .apiKey }),
                (.keys, shown.filter { !$0.signedIn && $0.method == .apiKey }),
            ]
            var listed: [(Section, [Row])] = []
            if !configurationRows.isEmpty {
                listed.append((.configurations, configurationRows))
            }
            listed += groups.filter { !$0.1.isEmpty }.map { (.group($0.0), $0.1.map(Row.account)) }
            // The fallback switch sits under every key it applies to, and
            // stays out of the way while the reader searches for one.
            if !listed.isEmpty, query.isEmpty {
                listed.append((.group(.fallback), [.fallback]))
            }
            sections = listed.isEmpty ? [(.status, [.status(.noResults)])] : listed
        }
        dataSource.update(sections)
        addButton.isEnabled = !addableProviders.isEmpty
    }

    /// The keys saved at one address, in the order the model picker sees them.
    /// The detail page uses the same definition, so the A/B letters agree.
    func keys(for configuration: ModelConfiguration) -> [AgentAccount] {
        accounts.filter { $0.signedIn && ModelConfiguration.from($0) == configuration }
    }

    /// Every group the listing knows: those with keys, and those given a name
    /// and an address before any key was saved. A group with no keys is still
    /// here, so signing the last one out leaves the row in place.
    private func allConfigurations() -> [ModelConfiguration] {
        var seen = Set<ModelConfiguration>()
        var result: [ModelConfiguration] = []
        for account in accounts {
            guard let configuration = ModelConfiguration.from(account),
                  seen.insert(configuration).inserted
            else { continue }
            result.append(configuration)
        }
        for pending in PendingConfigurations.configurations() {
            guard let configuration = PendingConfigurations.configuration(fromStorageID: pending.id),
                  seen.insert(configuration).inserted
            else { continue }
            result.append(configuration)
        }
        return result
    }

    /// A name saved by an earlier build, before a configuration carried its
    /// address, has no group to join. It keeps its old row waiting for a key.
    private func legacyWaiting(in listed: [AgentAccount]) -> [AgentAccount] {
        let ids = Set(listed.map(\.id))
        return PendingConfigurations.configurations().compactMap { pending in
            guard pending.baseURL == nil, !ids.contains(pending.id),
                  let provider = AgentProfileID.kind(of: pending.id),
                  let signIn = listed.first(where: { $0.provider == provider })
            else { return nil }
            return AgentAccount(
                provider: provider,
                id: pending.id,
                method: signIn.method,
                alternativeMethods: signIn.alternativeMethods,
                signedIn: false,
                name: pending.name,
            )
        }
    }

    private func matches(_ account: AgentAccount) -> Bool {
        query.isEmpty
            || account.title.localizedStandardContains(query)
            || account.provider.displayName.localizedStandardContains(query)
    }

    private func matches(_ configuration: ModelConfiguration) -> Bool {
        query.isEmpty
            || configuration.title(keys: keys(for: configuration)).localizedStandardContains(query)
            || configuration.baseURL.localizedStandardContains(query)
            || configuration.provider.displayName.localizedStandardContains(query)
    }

    private func isStatus(_ section: Section) -> Bool {
        if case .status = section { return true }
        return false
    }

    private func isPreference(_ section: Section) -> Bool {
        if case .group(.fallback) = section { return true }
        return false
    }

    // MARK: - Table

    private func account(at indexPath: IndexPath) -> AgentAccount? {
        guard case let .account(account)? = dataSource.value(at: indexPath) else { return nil }
        return account
    }

    private func configuration(at indexPath: IndexPath) -> ModelConfiguration? {
        guard case let .configuration(configuration)? = dataSource.value(at: indexPath) else { return nil }
        return configuration
    }

    private func statusCell(_ status: Status) -> UITableViewCell {
        switch status {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Model Providers Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .noResults:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No Results")
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    /// One named Base URL: the name, the address and how many keys are saved
    /// there. Opening it lists the keys and adds more at the same address.
    private func configurationCell(_ configuration: ModelConfiguration) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        let members = keys(for: configuration)
        content.text = configuration.title(keys: members)
        let count = members.isEmpty
            ? String(localized: "Add Credential")
            : String(localized: "\(members.count) Keys")
        content.secondaryText = [
            configuration.provider.displayName,
            AgentEndpoint.title(configuration.baseURL),
            count,
        ].joined(separator: " · ")
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        content.textProperties.numberOfLines = 1
        content.image = configuration.provider.icon
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
        content.textToSecondaryTextVerticalPadding = 2
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// The provider's mark and name on one line; signed in, who as under the
    /// name and a `...` menu at the end, one waiting for its key the provider
    /// it is a configuration of.
    private func accountCell(_ account: AgentAccount) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content: UIListContentConfiguration
        if account.signedIn {
            content = .stackedValueCell()
            content.secondaryText = Self.signedInLine(account)
            Self.subtitleStyle(&content)
            cell.accessoryView = menuButton(account)
            cell.selectionStyle = .none
        } else if account.name != nil {
            content = .subtitleCell()
            content.secondaryText = Self.waitingLine(account)
            Self.subtitleStyle(&content)
            cell.accessoryView = menuButton(account)
            cell.selectionStyle = .none
        } else {
            content = .cell()
            cell.accessoryType = .disclosureIndicator
        }
        content.text = account.title
        content.textProperties.numberOfLines = 1
        content.image = account.provider.icon
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
        cell.contentConfiguration = content
        return cell
    }

    /// The one preference of this screen: a run that has no key left for its
    /// model, and whose failure was not the reader's own message's fault, may
    /// put that message to another enabled model. Off, it never does.
    private func fallbackCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = String(localized: "Try Another Model")
        content.secondaryText = String(localized: "Send the message again with another enabled model once no key left for this one can answer.")
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = ModelFallback.triesOtherModels
        toggle.accessibilityLabel = String(localized: "Try Another Model")
        toggle.addTarget(self, action: #selector(fallbackToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc private func fallbackToggled(_ sender: UISwitch) {
        ModelFallback.triesOtherModels = sender.isOn
    }

    /// Who it is signed in as, under the name; a named configuration says
    /// which provider it is a configuration of, as its name may not.
    private static func signedInLine(_ account: AgentAccount) -> String {
        var parts: [String] = []
        if account.name != nil {
            parts.append(account.provider.displayName)
        }
        parts.append(account.account ?? String(localized: "Signed In"))
        if let expiresAt = account.expiresAt {
            let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
            parts.append(expiresAt < Date() ? String(localized: "Expired \(date)") : String(localized: "Until \(date)"))
        }
        return parts.joined(separator: " · ")
    }

    /// What a configuration named but not given a key yet says under its name:
    /// which provider it is a configuration of, and what it is missing.
    private static func waitingLine(_ account: AgentAccount) -> String {
        [account.provider.displayName, String(localized: "Add Credential")].joined(separator: " · ")
    }

    /// How every subtitle under a name reads, whichever sentence it holds.
    private static func subtitleStyle(_ content: inout UIListContentConfiguration) {
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        content.textToSecondaryTextVerticalPadding = 2
    }

    /// `…` with no circle, its menu read each time it opens.
    private func menuButton(_ account: AgentAccount) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.accountActions(account) ?? [])
        }])
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 44)
        button.accessibilityLabel = String(localized: "\(account.title) Options")
        return button
    }

    private func accountActions(_ account: AgentAccount) -> [UIMenuElement] {
        // A name saved before configurations carried an address has no
        // credential to edit: rename it, or take the name away.
        guard account.signedIn else {
            var actions: [UIMenuElement] = []
            if PendingConfigurations.contains(account.id) {
                actions.append(UIAction(
                    title: String(localized: "Rename"),
                    image: UIImage(systemName: "pencil.line"),
                ) { [weak self] _ in
                    self?.renameWaiting(account)
                })
            }
            actions.append(UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Remove"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    PendingConfigurations.remove(account.id)
                    self?.load()
                },
            ]))
            return actions
        }

        var actions: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Edit"),
                image: UIImage(systemName: account.isAPIKeyAccount ? "pencil" : "arrow.clockwise"),
            ) { [weak self] _ in
                self?.signIn(account)
            },
            UIAction(
                title: String(localized: "Models"),
                image: UIImage(systemName: "checklist"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelActivationController(account: account))
            },
        ]
        // A provider that takes several configurations offers one more here,
        // beside the ones it has.
        if AgentProfileID.canonicalID(for: account.provider) != nil {
            actions.append(UIAction(
                title: String(localized: "Add Configuration"),
                image: UIImage(systemName: "plus"),
            ) { [weak self] _ in
                self?.addConfiguration(provider: account.provider)
            })
        }
        actions.append(UIMenu(options: .displayInline, children: [
            UIAction(
                title: String(localized: "Sign Out"),
                image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                attributes: .destructive,
            ) { [weak self] _ in
                self?.confirmSignOut(account)
            },
        ]))
        return actions
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if configuration(at: indexPath) != nil { return true }
        return account(at: indexPath).map { !$0.signedIn } ?? false
    }

    /// A configuration goes only from its detail page, where every key it
    /// holds can be named; here a swipe still removes a name left waiting by
    /// an earlier build.
    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let account = account(at: indexPath), !account.signedIn,
              PendingConfigurations.contains(account.id)
        else { return nil }
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove"),
        ) { [weak self] _, _, completion in
            PendingConfigurations.remove(account.id)
            self?.load()
            completion(true)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let account = account(at: indexPath),
              !account.signedIn, PendingConfigurations.contains(account.id)
        else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.accountActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let configuration = configuration(at: indexPath) {
            open(configuration)
            return
        }
        guard let account = account(at: indexPath), !account.signedIn else { return }
        signIn(account)
    }

    // MARK: - Acting

    private func signIn(
        _ account: AgentAccount,
        preferredProfileName: String? = nil,
        seedValues: [String: String]? = nil,
    ) {
        let page = ProviderLoginController(
            account: account,
            preferredProfileName: preferredProfileName,
            seedValues: seedValues,
        )
        page.onFinish = { [weak self] in self?.load() }
        // a sheet of its own over Settings, kept up until it is closed: a
        // stray swipe would end a sign-in waiting on Safari
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    /// A name saved before configurations carried an address keeps its old
    /// row: rename it where it is, without asking the keychain for anything.
    private func renameWaiting(_ account: AgentAccount) {
        promptForName(initial: account.name) { [weak self] newName in
            PendingConfigurations.remove(account.id)
            PendingConfigurations.save(newName, for: account.id)
            self?.load()
        }
    }

    private func promptForName(initial: String?, handler: @escaping (String) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "Rename"),
            message: nil,
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.text = initial
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default) { [alert] _ in
            guard let value = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.count <= 120, !value.contains(where: \.isNewline) else { return }
            handler(value)
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
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }

    /// Opening a configuration shows its keys, and is where more are added.
    /// The detail page reads the same listing back when it is changed.
    private func open(_ configuration: ModelConfiguration) {
        let page = ConfigurationKeysController(
            configuration: configuration,
            accounts: accounts,
        ) { [weak self] in
            self?.load()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// A new configuration is a name and a canonical Base URL first. Its keys
    /// are added on the detail page: none of them exists yet, and the address
    /// is already known, so the sign-in page asks only for a secret. The name
    /// is kept before opening the page, so leaving it half-read loses nothing.
    private func addConfiguration(provider: AgentProvider) {
        let alert = UIAlertController(
            title: String(localized: "Add Configuration"),
            message: String(localized: "Name this configuration and the address its keys point to."),
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .words
        }
        alert.addTextField { field in
            field.placeholder = String(localized: "Base URL")
            field.keyboardType = .URL
            field.textContentType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Continue"), style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline) else {
                presentNotice(title: "Invalid Name", message: "Up to 120 characters.")
                return
            }
            let address = alert.textFields?.last?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let baseURL = AgentEndpoint.canonical(address) else {
                presentNotice(title: "Invalid Base URL", message: "Enter a valid address, such as https://api.example.com/v1.")
                return
            }
            let configuration = ModelConfiguration(provider: provider, baseURL: baseURL)
            PendingConfigurations.save(name, baseURL: baseURL, for: configuration.storageID)
            load()
            open(configuration)
        })
        present(alert, animated: true)
    }
}
