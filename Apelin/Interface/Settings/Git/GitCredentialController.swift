import ApelinProtocol
import SPIndicator
import UIKit

/// Adds, or replaces, the HTTPS credential for one host: its name, a
/// username and a token. The token goes to the host in the request and
/// nowhere else; the field is emptied once it has gone. Settings ▸ Git
/// reads the list again when it comes back.
final class GitCredentialController: TableController {
    private enum Row: Hashable {
        case host
        case username
        case token
    }

    private lazy var dataSource = TableDataSource<Row, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cells[row]
    }

    private let hostField = UITextField()
    private let usernameField = UITextField()
    private let tokenField = UITextField()
    private var cells: [Row: UITableViewCell] = [:]
    private var isSaving = false

    private lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.save() },
    )

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Add Credential")
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        let fields: [(Row, UITextField, String, String)] = [
            (.host, hostField, String(localized: "Host"), "github.com"),
            (.username, usernameField, String(localized: "Username"), String(localized: "Username")),
            (.token, tokenField, String(localized: "Token"), String(localized: "Personal Access Token")),
        ]
        for (index, (row, field, label, placeholder)) in fields.enumerated() {
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.clearButtonMode = .whileEditing
            field.keyboardType = row == .host ? .URL : .asciiCapable
            field.returnKeyType = index == fields.count - 1 ? .done : .next
            field.accessibilityLabel = label
            field.placeholder = placeholder
            field.addAction(UIAction { [weak self] _ in self?.updateSave() }, for: .editingChanged)
            field.addAction(UIAction { [weak self] _ in self?.advance(from: index) }, for: .editingDidEndOnExit)
            cells[row] = GitSettingsController.cell(containing: field)
        }
        usernameField.textContentType = .username
        tokenField.isSecureTextEntry = true
        dataSource.headerTitle = { row in
            switch row {
            case .host: String(localized: "Host")
            case .username: String(localized: "Username")
            case .token: String(localized: "Token")
            }
        }
        dataSource.footerTitle = { row in
            switch row {
            case .host: String(localized: "A credential is offered only to remotes on this host. Saving one for a host replaces the one it had.")
            case .username: nil
            case .token: String(localized: "A personal access token that can read the repositories you clone, and write those you push to.")
            }
        }
        dataSource.update([(.host, [.host]), (.username, [.username]), (.token, [.token])])
        updateSave()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isSaving, (hostField.text ?? "").isEmpty {
            hostField.becomeFirstResponder()
        }
    }

    /// What the host field names: a host, with `:port` when given. A pasted
    /// address gives its host; anything with a path or a user left in it is
    /// not one.
    private static func host(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("://") {
            guard let url = URLComponents(string: trimmed), url.user == nil,
                  let host = url.host, !host.isEmpty
            else { return nil }
            return url.port.map { "\(host):\($0)" } ?? host
        }
        guard !trimmed.isEmpty, !trimmed.contains(where: { "/@?# ".contains($0) }) else { return nil }
        return trimmed
    }

    private static func trimmed(_ field: UITextField) -> String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isReady: Bool {
        [hostField, usernameField, tokenField].allSatisfy { !Self.trimmed($0).isEmpty }
    }

    private func updateSave() {
        saveItem.isEnabled = isReady && !isSaving
        [hostField, usernameField, tokenField].forEach { $0.isEnabled = !isSaving }
    }

    private func advance(from index: Int) {
        let order = [hostField, usernameField, tokenField]
        if index + 1 < order.count {
            order[index + 1].becomeFirstResponder()
        } else {
            save()
        }
    }

    private func save() {
        guard isReady, !isSaving else { return }
        guard let host = Self.host(from: hostField.text ?? "") else {
            presentNotice(
                title: "Check the Host",
                message: "Enter a host name, such as github.com, without a path or username.",
            )
            return
        }
        view.endEditing(true)
        isSaving = true
        updateSave()
        let request = GitCredentialSetRequest(
            host: host,
            username: Self.trimmed(usernameField),
            token: Self.trimmed(tokenField),
        )
        Task { [weak self] in
            do {
                try await ApelinService.app.gitCredentialSet(request)
                guard let self else { return }
                tokenField.text = nil
                SPIndicator.present(title: String(localized: "Credential Saved"), preset: .done, haptic: .success)
                navigationController?.popViewController(animated: true)
            } catch {
                guard let self else { return }
                isSaving = false
                updateSave()
                presentNotice(title: "Unable to Save Credential", message: error.readableMessage)
            }
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        false
    }
}
