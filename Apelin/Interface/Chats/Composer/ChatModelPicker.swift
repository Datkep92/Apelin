import ApelinProtocol
import UIKit

/// One row of the picker's two pages: a configuration, one of its models, or
/// a query nothing matched. The item identifier tells rows apart within a
/// snapshot, which two configurations enabling the same model id need.
private enum PickerRow: Equatable {
    /// The configuration at this index: the title on the row, its mark, and
    /// what the line under the title holds.
    case configuration(Int, String, AgentProvider, String?)
    /// One model of the configuration at this index: the model, what the
    /// line under it holds (a search result names its configuration there),
    /// and whether the composer sends with it now.
    case model(Int, String, String?, Bool)
    case empty

    var id: String {
        switch self {
        case let .configuration(index, _, _, _): "configuration \(index)"
        case let .model(index, model, _, _): "model \(index) \(model)"
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
    case .empty:
        content.text = String(localized: "No Results")
        content.textProperties.color = .secondaryLabel
        content.textProperties.alignment = .center
        cell.selectionStyle = .none
    }
    cell.contentConfiguration = content
    return cell
}

/// The line under a configuration's title: what the account is signed in
/// as, or the provider when nothing else tells where the row leads.
private func pickerDetail(for account: AgentAccount) -> String? {
    if let host = account.account { return host }
    return account.name == nil ? nil : account.provider.displayName
}

/// Whether `account`'s `model` is the one the composer sends with now: the
/// same provider and configuration, the same model.
private func pickerHolds(_ model: String, _ account: AgentAccount, _ selected: ComposerModelSelection?) -> Bool {
    guard let selected else { return false }
    return selected.provider == account.provider
        && selected.profileID == account.profileID
        && selected.model == model
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
    private var selected: ComposerModelSelection?
    private var query = ""
    private var sections: [(Section, [PickerRow])] = []
    private let search = UISearchController(searchResultsController: nil)

    private lazy var dataSource = TableDataSource<Section, String, PickerRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { _, _, row in
        pickerCell(row)
    }

    init(accounts: [AgentAccount], selected: ComposerModelSelection?) {
        self.accounts = accounts
        self.selected = selected
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
            let rows = accounts.indices.map { index -> PickerRow in
                let account = accounts[index]
                return .configuration(index, account.title, account.provider, pickerDetail(for: account))
            }
            sections = [(.configurations, rows.isEmpty ? [.empty] : rows)]
            dataSource.update(sections)
            return
        }
        let matched = accounts.indices.compactMap { index -> (Section, [PickerRow])? in
            let account = accounts[index]
            let models = (account.models ?? []).filter { $0.localizedStandardContains(query) }
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
        case let .configuration(index, _, _, _):
            let page = ChatModelListController(
                accounts: accounts,
                index: index,
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
        ComposerModelSelection.current = choice
        navigationController?.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}

/// One configuration's models, pushed over the picker: they are the models
/// the configuration enables, with the composer's own marked. The search
/// belongs to the page behind, which already reaches every configuration.
private final class ChatModelListController: TableController {
    private let accounts: [AgentAccount]
    private let index: Int
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
        index: Int,
        selected: ComposerModelSelection?,
        onPick: @escaping (AgentAccount, String) -> Void,
    ) {
        self.accounts = accounts
        self.index = index
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
        title = accounts[index].title
        rewrite()
    }

    /// Every model of this one configuration, the composer's own marked.
    private func rewrite() {
        let account = accounts[index]
        let rows = (account.models ?? []).map { model in
            PickerRow.model(index, model, nil, pickerHolds(model, account, selected))
        }
        dataSource.update([(0, rows)])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .model(_, model, _, _) = dataSource.value(at: indexPath) else { return }
        onPick(accounts[index], model)
    }
}
