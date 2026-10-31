import AlertController
import ApelinProtocol
import Then
import UIKit

/// Settings ▸ Model Providers: every provider apelin-agent can sign in to,
/// in the order it lists them (kwwk's). Signed-in ones first, each with who
/// it is signed in as under its name and a `...` menu (Edit Configuration or Sign In Again, Sign
/// Out); then the rest, those signed in to with an account apart from those
/// that take a typed key. A search field narrows the list by name, and `+`
/// adds another configuration of a provider that keeps several; one named but
/// not yet given a key has a row too, under the provider it is a configuration
/// of, and swiping it takes the name away. Signing out gives up a key and
/// leaves a row behind; a configuration is also deleted for good — its key out
/// of the keychain and its name off the list — from its menu, or by a swipe.
/// The provider's own row is only ever signed out of: apelin-agent lists it
/// whether the keychain holds a key for it or not.
final class ModelProvidersController: TableController, UISearchResultsUpdating {
    private enum Group: Hashable {
        case signedIn
        case accounts
        case keys

        var title: String {
            switch self {
            case .signedIn: String(localized: "Signed In")
            case .accounts: String(localized: "Sign In with an Account")
            case .keys: String(localized: "API Keys")
            }
        }
    }

    private enum Status: Equatable {
        case loading
        case unavailable(String)
        case noResults
    }

    private enum Section: Hashable {
        case group(Group)
        case status
    }

    private enum Row: Equatable {
        case account(AgentAccount)
        case status(Status)
        var id: String {
            switch self {
            case let .account(account): account.id
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
        case let .account(account): return accountCell(account)
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

    /// One action per such provider, titled by the provider itself: a name
    /// is asked for next, then the provider's own sign-in page.
    private func addActions() -> [UIMenuElement] {
        addableProviders.map { provider in
            UIAction(title: provider.displayName, image: provider.icon) { [weak self] _ in
                self?.addConfiguration(provider)
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
            if case let .group(group) = section {
                return group.title
            }
            return nil
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, section == sections.last?.0, case .group = section else { return nil }
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
                // A configuration the listing now carries names itself, out of
                // the credential this page had not saved yet.
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
            let shown = (accounts + waiting(in: accounts)).filter(matches)
            let groups: [(Group, [AgentAccount])] = [
                (.signedIn, shown.filter(\.signedIn)),
                (.accounts, shown.filter { !$0.signedIn && $0.method != .apiKey }),
                (.keys, shown.filter { !$0.signedIn && $0.method == .apiKey }),
            ]
            sections = groups.filter { !$0.1.isEmpty }.map { (.group($0.0), $0.1.map(Row.account)) }
            if sections.isEmpty {
                sections = [(.status, [.status(.noResults)])]
            }
        }
        dataSource.update(sections)
        addButton.isEnabled = !addableProviders.isEmpty
    }

    /// A configuration named through `+` that the listing has not caught up
    /// with: it has no row of its own until its key is saved, so one is made
    /// from the name the reader gave it and the provider's own entry for how
    /// it signs in.
    private func waiting(in listed: [AgentAccount]) -> [AgentAccount] {
        let ids = Set(listed.map(\.id))
        return PendingConfigurations.waiting().compactMap { pending in
            guard !ids.contains(pending.id),
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

    // MARK: - Table

    private func account(at indexPath: IndexPath) -> AgentAccount? {
        guard case let .account(account)? = dataSource.value(at: indexPath) else { return nil }
        return account
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
            cell.accessoryType = .disclosureIndicator
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
        // A provider that takes several API keys or endpoints offers one
        // more here, beside the ones it has.
        if AgentProfileID.canonicalID(for: account.provider) != nil {
            actions.append(UIAction(
                title: String(localized: "Add Configuration"),
                image: UIImage(systemName: "plus"),
            ) { [weak self] _ in
                self?.addConfiguration(account.provider)
            })
        }
        // The two red ones, the lesser first: Sign Out gives up the key and
        // leaves the row, Delete takes a configuration away altogether.
        var endings: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Sign Out"),
                image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                attributes: .destructive,
            ) { [weak self] _ in
                self?.confirmSignOut(account)
            },
        ]
        if account.profileID != nil {
            endings.append(UIAction(
                title: String(localized: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in
                self?.confirmDelete(account)
            })
        }
        actions.append(UIMenu(options: .displayInline, children: endings))
        return actions
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        account(at: indexPath).map { !$0.signedIn } ?? false
    }

    /// A configuration still waiting for its key has nothing to sign out of, so
    /// a swipe takes the name away instead: the walk back to `+` is the long
    /// way round to the same thing. A saved one is deleted the same way, and
    /// asks first, since its key goes with it.
    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let account = account(at: indexPath) else { return nil }
        if PendingConfigurations.contains(account.id) {
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
        guard account.signedIn, account.profileID != nil else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            self?.confirmDelete(account)
            completion(false)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let account = account(at: indexPath), account.signedIn else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.accountActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let account = account(at: indexPath), !account.signedIn else { return }
        signIn(account)
    }

    // MARK: - Acting

    private func signIn(_ account: AgentAccount) {
        let page = ProviderLoginController(account: account)
        page.onFinish = { [weak self] in self?.load() }
        // a sheet of its own over Settings, kept up until it is closed: a
        // stray swipe would end a sign-in waiting on Safari
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
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
                // What the alert promised is a later sign-in, so an added
                // configuration keeps its name and stays as a row waiting for
                // the next key; the provider's own row has no name to keep.
                if account.profileID != nil, let name = account.name {
                    PendingConfigurations.save(name, for: account.id)
                } else {
                    PendingConfigurations.remove(account.id)
                }
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }

    /// A key is not given up on a stray tap: the alert is where deleting is
    /// asked for the last time.
    private func confirmDelete(_ account: AgentAccount) {
        presentConfirmation(
            title: "Delete \(account.title)?",
            message: "The saved key is removed from this device’s keychain. This cannot be undone.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            self?.delete(account)
        }
    }

    /// Delete: the key out of the keychain, where Sign Out leaves a row
    /// waiting for the next one. A name that never reached a key goes from
    /// here alone, without asking apelin-agent for anything.
    private func delete(_ account: AgentAccount) {
        guard account.signedIn else {
            PendingConfigurations.remove(account.id)
            load()
            return
        }
        Task { [weak self] in
            do {
                try await ApelinService.app.agentSignOut(provider: account.provider, profileID: account.profileID)
                EnabledModels.remove(for: account)
                PendingConfigurations.remove(account.id)
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Delete", message: error.readableMessage)
            }
        }
    }

    /// A name for one more configuration of `provider`, then its sign-in: the
    /// name is kept here until the key is saved, so the page can be left and
    /// the row returned to rather than named again.
    private func addConfiguration(_ provider: AgentProvider) {
        // How the provider signs in is apelin-agent's answer, taken from the
        // entry it lists for the provider itself.
        guard let id = AgentProfileID.make(for: provider),
              let listed = accounts.first(where: { $0.provider == provider })
        else { return }
        present(AlertInputViewController(
            title: "Add Configuration",
            message: "Name this configuration. It appears beside the provider in the model menu.",
            placeholder: "Name",
            text: "",
            doneButtonText: "Continue",
        ) { [weak self] value in
            guard let self else { return }
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline) else {
                presentNotice(title: "Invalid Name", message: "Up to 120 characters.")
                return
            }
            // Saved before the page opens: the row is there to come back to
            // whether or not the key is ever typed in — and the list is read
            // again now, rather than trusted to the page's dismissal, which
            // the page under a form sheet is not told of.
            PendingConfigurations.save(name, for: id)
            load()
            signIn(AgentAccount(
                provider: provider,
                id: id,
                method: listed.method,
                alternativeMethods: listed.alternativeMethods,
                signedIn: false,
                name: name,
            ))
        }, animated: true)
    }
}
