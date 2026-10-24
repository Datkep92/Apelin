import ApelinProtocol
import UIKit

final class PermissionModeController: TableController {
    private let modes: [ApprovalMode] = [.confirm, .relaxed, .full]

    private struct Row: Equatable {
        let mode: ApprovalMode
        let selected: Bool
    }

    private lazy var dataSource = TableDataSource<Int, ApprovalMode, Row>(
        tableView: tableView,
        identifier: { $0.mode },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private func updateRows() {
        dataSource.footerTitle = { _ in AgentPermissions.explanation }
        dataSource.update([(0, modes.map { Row(mode: $0, selected: $0 == AgentPermissions.mode) })], reconfigure: true)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Permission Mode")
        updateRows()
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "mode")
            ?? UITableViewCell(style: .default, reuseIdentifier: "mode")
        let mode = row.mode
        var content = cell.defaultContentConfiguration()
        content.text = AgentPermissions.title(for: mode)
        cell.contentConfiguration = content
        let selected = row.selected
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let mode = dataSource.value(at: indexPath)?.mode else { return }
        let current = AgentPermissions.mode
        guard mode != current else { return }
        switch mode {
        // Root without asking: confirmed in words, then by the device owner.
        // Leaving Full never asks.
        case .full:
            presentConfirmation(
                title: "Enable Full Mode?",
                message: "The agent can run commands as root without asking, with full control of this device. Each chat switches when you send its next message.",
                confirmTitle: "Enable Full Mode",
                destructive: true,
            ) { [weak self] in
                Task { @MainActor in
                    guard await DeviceOwnerCheck.confirm(
                        reason: String(localized: "Let the agent run commands as root without asking."),
                    ) else { return }
                    self?.save(mode)
                }
            }
        case .relaxed where current == .confirm:
            presentConfirmation(
                title: "Enable Relaxed Mode?",
                message: "The agent can run commands and make changes without asking, within the app’s permissions. Each chat switches when you send its next message.",
                confirmTitle: "Enable Relaxed Mode",
            ) { [weak self] in self?.save(mode) }
        default:
            save(mode)
        }
    }

    private func save(_ mode: ApprovalMode) {
        AgentPermissions.mode = mode
        updateRows()
    }
}
