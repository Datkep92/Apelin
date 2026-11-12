import ApelinProtocol
import UIKit

/// One row of the picker's two pages: a configuration, one of its models, or
/// a query nothing matched. The item identifier tells rows apart within a
/// snapshot, which two configurations enabling the same model id need.
private enum PickerRow: Equatable {
    /// One provider group (possibly several configurations): the group index,
    /// its title, provider mark, and the line under the title.
    case configuration(Int, String, AgentProvider, String?)
    /// One model of the configuration at this index: the model, what the
    /// line under it holds (a search result names its configuration there),
    /// and whether the composer sends with it now.
    case model(Int, String, String?, Bool)
    /// One model several of the group's configurations serve: the model, the
    /// account indices that serve it, the line under it naming them, and
    /// whether one of them is what the composer sends with now. Opening it
    /// is how a key is chosen: the model is still named once.
    case modelKeys(String, [Int], String?, Bool)
    /// One configuration that can serve the model of the page this is
    /// pushed over: the account index, its name, the address under it, and
    /// whether it is the key in use.
    case key(Int, String, String?, Bool)
    case empty

    var id: String {
        switch self {
        case let .configuration(index, _, _, _): "configuration \(index)"
        case let .model(index, model, _, _): "model \(index) \(model)"
        case let .modelKeys(model, _, _, _): "model keys \(model)"
        case let .key(index, _, _, _): "key \(index)"
        case .empty: "empty"
        }
    }
}

/// The cell for one row, drawn anew each time it lands: neither page reuses
/// a cell, so two different rows never meet in the same view.
private func pickerCell(_ row: PickerRow) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    var content = UIListContentConfiguration.subtitleCell()
    content.secondaryTextProperties.color = .secondaryLabel
    content.secondaryTextProperties.numberOfLines = 1
    content.textProperties.numberOfLines = 1
    content.textToSecondaryTextVerticalPadding = 2
    switch row {
    case let .configuration(_, title, provider, detail):
        content.text = title
        content.secondaryText = detail
        content.image = provider.icon
        content.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        content.imageProperties.reservedLayoutSize = CGSize(width: 29, height: 29)
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityTraits = .button
    case let .model(_, model, detail, picked):
        content.text = model
        content.secondaryText = detail
        content.textProperties.numberOfLines = 0
        cell.accessoryType = picked ? .checkmark : .none
        cell.accessibilityTraits = picked ? [.button, .selected] : [.button]
    case let .modelKeys(model, _, detail, picked):
        content.text = model
        content.secondaryText = detail
        content.textProperties.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityTraits = picked ? [.button, .selected] : [.button]
    case let .key(_, name, detail, picked):
        content.text = name
        content.secondaryText = detail
        content.textProperties.numberOfLines = 0
        cell.accessoryType = picked ? .checkmark : .none
        cell.accessibilityTraits = picked ? [.button, .selected] : [.button]
    case .empty:
        content.text = String(localized: "No Results")
        content.textProperties.color = .secondaryLabel
        content.textProperties.alignment = .center
        cell.selectionStyle = .none
    }
    cell.contentConfiguration = content
    return cell
}

/// The line under a configuration's title: the Base URL its requests go to,
/// so two keys at two addresses on one host are told apart, the host when
/// only that is known, or the provider when nothing else tells where the row
/// leads.
private func pickerDetail(for account: AgentAccount) -> String? {
    if let endpoint = account.endpoint { return AgentEndpoint.title(endpoint) }
    if let host = account.account { return host }
    return account.name == nil ? nil : account.provider.displayName
}

/// The line under a key's name on the key list: the address it sends to.
private func pickerKeyDetail(for account: AgentAccount) -> String? {
    if let endpoint = account.endpoint { return AgentEndpoint.title(endpoint) }
    return account.account
}

/// The configurations of one group, each named so two are told apart without
/// a secret. `ModelKeys` is the one place that decides it, so a key of a
/// model's list here reads exactly as it does in the composer's key menu:
/// `Relay - API Key A`, the letter standing for its place in the list.
private func pickerKeyLabels(_ indices: [Int], _ accounts: [AgentAccount]) -> [String] {
    ModelKeys.labels(indices.map { accounts[$0] }, title: \.title)
}

/// Whether `account`'s `model` is the one the composer sends with now: the
/// same provider and configuration, the same model.
private func pickerHolds(_ model: String, _ account: AgentAccount, _ selected: ComposerModelSelection?) -> Bool {
    guard let selected else { return false }
    return selected.provider == account.provider
        && selected.profileID == account.profileID
        && selected.model == model
}

/// The configuration's models, each named once. The server sends names as
/// an array, which may repeat; two rows alike would ask the snapshot for one
/// identifier twice, and a snapshot answers such a request by throwing.
private func pickerModels(_ account: AgentAccount) -> [String] {
    var seen: Set<String> = []
    return (account.models ?? []).filter { seen.insert($0).inserted }
}

/// The sheet the composer's model button opens: the enabled configurations
/// first, each one opening its own models, and a search field answering
/// over every model of every configuration at once. The context menu this
/// replaced had nowhere to type, so a search could not be part of it.
final class ChatModelPickerController: TableController, UISearchResultsUpdating {
    private enum Section: Hashable {
        /// The configurations themselves, while nothing is typed.
        case configurations
        /// The models of one configuration the typed query matched.
        case matches(Int)
        /// A query nothing matched.
        case noResults
    }

    /// The configurations as the composer's own list held them when the
    /// sheet opened: signed in, enabled, each with something to choose.
    private let accounts: [AgentAccount]
    private let groups: [ModelPickerGrouping.Group]
    private var selected: ComposerModelSelection?
    private var query = ""
    private var sections: [(Section, [PickerRow])] = []
    private let search = UISearchController(searchResultsController: nil)
    private let onPickModel: ((ComposerModelSelection) -> Void)?

    private lazy var dataSource = TableDataSource<Section, String, PickerRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { _, _, row in
        pickerCell(row)
    }

    init(accounts: [AgentAccount], selected: ComposerModelSelection?, onPickModel: ((ComposerModelSelection) -> Void)? = nil) {
        self.accounts = accounts
        self.selected = selected
        self.onPickModel = onPickModel
        self.groups = ModelPickerGrouping.groups(of: accounts, title: \.title)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Select Model")
        navigationItem.backButtonDisplayMode = .minimal
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Models")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        dataSource.headerTitle = { [weak self] section in
            self?.header(section)
        }
        regroup()
    }

    func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        regroup()
    }

    private func header(_ section: Section) -> String? {
        switch section {
        case .configurations: nil
        case let .matches(index): accounts[index].title
        case .noResults: nil
        }
    }

    /// The rows shown now: one per configuration while nothing is typed,
    /// and after something is typed, the matching models each under a header
    /// naming the configuration they belong to.
    private func regroup() {
        guard !query.isEmpty else {
            let rows = groups.enumerated().map { groupIndex, group -> PickerRow in
                let first = accounts[group.indices[0]]
                let title = group.title
                let detail: String? = group.indices.count > 1
                    ? "\(group.indices.count) configurations"
                    : pickerDetail(for: first)
                return .configuration(groupIndex, title, group.provider, detail)
            }
            sections = [(.configurations, rows.isEmpty ? [.empty] : rows)]
            dataSource.update(sections)
            return
        }
        let matched = accounts.indices.compactMap { index -> (Section, [PickerRow])? in
            let account = accounts[index]
            let models = pickerModels(account).filter { $0.localizedStandardContains(query) }
            guard !models.isEmpty else { return nil }
            let rows = models.map { model in
                PickerRow.model(index, model, nil, pickerHolds(model, account, selected))
            }
            return (.matches(index), rows)
        }
        sections = matched.isEmpty ? [(.noResults, [.empty])] : matched
        dataSource.update(sections)
    }

    // MARK: - Table

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case let .configuration(groupIndex, _, _, _):
            let indices = groups[groupIndex].indices
            let page = ChatModelListController(
                accounts: accounts,
                indices: indices,
                groupTitle: groups[groupIndex].title,
                selected: selected,
                onPick: { [weak self] account, model in
                    guard let self else { return }
                    pick(model, in: account)
                },
            )
            navigationController?.pushViewController(page, animated: true)
        case let .model(index, model, _, _):
            pick(model, in: accounts[index])
        default:
            break
        }
    }

    /// The reader's model: the composer sends with it from now on, and the
    /// sheet closes over the message it was opened from.
    private func pick(_ model: String, in account: AgentAccount) {
        let choice = ChatController.selection(of: model, in: account)
        selected = choice
        onPickModel?(choice)
        ComposerModelSelection.current = choice
        navigationController?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

/// One configuration's models, pushed over the picker: they are the models
/// the configuration enables, with the composer's own marked. The search
/// belongs to the page behind, which already reaches every configuration.
private final class ChatModelListController: TableController {
    private let accounts: [AgentAccount]
    private let indices: [Int]
    /// What the picker's row this page was pushed from is called: the shared
    /// Base URL when the group holds several configurations.
    private let groupTitle: String
    private let selected: ComposerModelSelection?
    private let onPick: (AgentAccount, String) -> Void

    private lazy var dataSource = TableDataSource<Int, String, PickerRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { _, _, row in
        pickerCell(row)
    }

    init(
        accounts: [AgentAccount],
        indices: [Int],
        groupTitle: String,
        selected: ComposerModelSelection?,
        onPick: @escaping (AgentAccount, String) -> Void,
    ) {
        self.accounts = accounts
        self.indices = indices
        self.groupTitle = groupTitle
        self.selected = selected
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = indices.count == 1
            ? accounts[indices[0]].title
            : groupTitle
        rewrite()
    }

    /// Every model across the selected configurations, each named once: a
    /// model one configuration serves is picked here, and one several of
    /// them serve opens the list of the keys that can send it, so no model
    /// is listed twice and no key is out of reach.
    private func rewrite() {
        var order: [String] = []
        var servers: [String: [Int]] = [:]
        for accountIndex in indices {
            for model in pickerModels(accounts[accountIndex]) where servers[model]?.contains(accountIndex) != true {
                if servers[model] == nil { order.append(model) }
                servers[model, default: []].append(accountIndex)
            }
        }
        let many = indices.count > 1
        let rows: [PickerRow] = order.compactMap { model in
            guard let list = servers[model], let first = list.first else { return nil }
            let picked = list.contains { pickerHolds(model, accounts[$0], selected) }
            guard list.count > 1 else {
                return .model(first, model, many ? accounts[first].title : nil, picked)
            }
            let names = pickerKeyLabels(list, accounts).joined(separator: " · ")
            return .modelKeys(model, list, names, picked)
        }
        dataSource.update([(0, rows)])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case let .model(accountIndex, model, _, _):
            onPick(accounts[accountIndex], model)
        case let .modelKeys(model, list, _, _):
            let page = ChatModelKeyController(
                accounts: accounts,
                indices: list,
                model: model,
                selected: selected,
                onPick: onPick,
            )
            navigationController?.pushViewController(page, animated: true)
        default:
            break
        }
    }
}

/// The configurations that can serve one model, pushed over its page: a
/// reader with several keys on one Base URL picks which one sends, and the
/// model is still named once. Each key is named the way Settings names it —
/// never a secret — with the address under it.
private final class ChatModelKeyController: TableController {
    private let accounts: [AgentAccount]
    private let indices: [Int]
    private let model: String
    private let selected: ComposerModelSelection?
    private let onPick: (AgentAccount, String) -> Void

    private lazy var dataSource = TableDataSource<Int, String, PickerRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { _, _, row in
        pickerCell(row)
    }

    init(
        accounts: [AgentAccount],
        indices: [Int],
        model: String,
        selected: ComposerModelSelection?,
        onPick: @escaping (AgentAccount, String) -> Void,
    ) {
        self.accounts = accounts
        self.indices = indices
        self.model = model
        self.selected = selected
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = model
        let names = pickerKeyLabels(indices, accounts)
        let rows: [PickerRow] = indices.enumerated().map { position, index in
            let account = accounts[index]
            return .key(
                index,
                names[position],
                pickerKeyDetail(for: account),
                pickerHolds(model, account, selected),
            )
        }
        dataSource.update([(0, rows)])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .key(accountIndex, _, _, _) = dataSource.value(at: indexPath) else { return }
        onPick(accounts[accountIndex], model)
    }
}
