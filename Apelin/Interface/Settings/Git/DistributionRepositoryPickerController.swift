import ApelinProtocol
import Then
import UIKit

/// The signed-in account's own repositories, most recently updated first,
/// to link one as the package repository. A row says whether it is private
/// (Pages for a private repository needs a paid plan) and whether it has a
/// Pages site already.
final class DistributionRepositoryPickerController: TableController {
    private enum Row: Hashable {
        case loading
        case unavailable(String)
        case empty
        case repository(DistributionRepositoryCandidate)
    }

    private lazy var dataSource = TableDataSource<Int, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let onPick: (DistributionRepositoryCandidate) -> Void
    private var loader: Task<Void, Never>?

    init(onPick: @escaping (DistributionRepositoryCandidate) -> Void) {
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(onPick:)")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Link Repository")
        navigationItem.largeTitleDisplayMode = .never
        dataSource.footerTitle = { _ in
            String(localized: "Choose the repository your packages go to. Apelin adds what the package index needs and leaves everything else as it is.")
        }
        dataSource.update([(0, [.loading])])
        load()
    }

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            let rows: [Row]
            do {
                let list = try await ApelinService.app.distributionRepositoryList(repositories: true)
                rows = list.repositories.isEmpty ? [.empty] : list.repositories.map(Row.repository)
            } catch {
                rows = [.unavailable(error.readableMessage)]
            }
            guard !Task.isCancelled, let self else { return }
            dataSource.update([(0, rows)])
        }
    }

    private func cell(for row: Row) -> UITableViewCell {
        switch row {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Repositories Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .empty:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "This account has no repositories of its own.")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .repository(candidate):
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = candidate.fullName
            var notes: [String] = []
            if candidate.isPrivate {
                notes.append(String(localized: "Private"))
            }
            if candidate.hasPages {
                notes.append(String(localized: "Has GitHub Pages"))
            }
            if let description = candidate.description, !description.isEmpty {
                notes.append(description)
            }
            content.secondaryText = notes.isEmpty ? nil : notes.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .repository? = dataSource.value(at: indexPath) {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .repository(candidate)? = dataSource.value(at: indexPath) else { return }
        onPick(candidate)
    }
}
