import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Git: the author the agent's commits carry, saved from the bar,
/// and one HTTPS credential per host for clones, fetches and pushes. A
/// credential is listed by its host and username only; its token went to
/// apelin-environment's keychain item and never comes back. A trailing swipe
/// removes one, after a confirmation; the last row adds one
/// (`GitCredentialController`).
final class GitSettingsController: TableController {
    private enum Section: Hashable {
        case author
        case credentials
    }

    private enum Row: Hashable {
        case name
        case email
        case loading
        case unavailable(String)
        case credential(GitCredentialSummary)
        case add
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    /// What apelin-environment last answered; nil until it has.
    private var settings: GitSettingsResponse?
    private var failure: Error?
    private var loader: Task<Void, Never>?
    private var isSaving = false

    private let nameField = UITextField()
    private let emailField = UITextField()
    private lazy var nameCell = Self.cell(containing: nameField)
    private lazy var emailCell = Self.cell(containing: emailField)

    private lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.saveAuthor() },
    )

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Git")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = saveItem
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        configure(nameField, label: String(localized: "Name"), placeholder: String(localized: "Name"))
        nameField.textContentType = .name
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .next
        nameField.addAction(
            UIAction { [weak self] _ in self?.emailField.becomeFirstResponder() },
            for: .editingDidEndOnExit,
        )
        configure(emailField, label: String(localized: "Email"), placeholder: String(localized: "Email"))
        emailField.textContentType = .emailAddress
        emailField.keyboardType = .emailAddress
        emailField.autocapitalizationType = .none
        emailField.returnKeyType = .done
        emailField.addAction(UIAction { [weak self] _ in self?.saveAuthor() }, for: .editingDidEndOnExit)
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .author: String(localized: "Author")
            case .credentials: String(localized: "HTTPS Credentials")
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case .author: String(localized: "Commits in your projects carry this name and email.")
            case .credentials: String(localized: "A token is used as the HTTPS password. It is kept only in this device's keychain and never synced.")
            }
        }
        updateControls()
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    // MARK: - Loading

    private func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let answer = try await ApelinService.app.gitSettings()
                guard !Task.isCancelled, let self else { return }
                showAuthor(of: answer)
                settings = answer
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            updateControls()
            updateRows()
        }
    }

    /// The saved author in the fields, unless the user has typed over the
    /// last one shown.
    private func showAuthor(of answer: GitSettingsResponse) {
        if nameField.text ?? "" == settings?.authorName ?? "" {
            nameField.text = answer.authorName
        }
        if emailField.text ?? "" == settings?.authorEmail ?? "" {
            emailField.text = answer.authorEmail
        }
    }

    private func updateRows() {
        let credentials: [Row] = if let settings {
            settings.credentials.map(Row.credential) + [.add]
        } else if let failure {
            [.unavailable(failure.readableMessage)]
        } else {
            [.loading]
        }
        dataSource.update([(.author, [.name, .email]), (.credentials, credentials)])
    }

    // MARK: - The author

    private static func trimmed(_ field: UITextField) -> String {
        (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var authorChanged: Bool {
        guard let settings else { return false }
        return Self.trimmed(nameField) != settings.authorName ?? ""
            || Self.trimmed(emailField) != settings.authorEmail ?? ""
    }

    private func updateControls() {
        let editable = settings != nil && !isSaving
        nameField.isEnabled = editable
        emailField.isEnabled = editable
        saveItem.isEnabled = editable && authorChanged
    }

    private func saveAuthor() {
        guard saveItem.isEnabled else { return }
        view.endEditing(true)
        let name = Self.trimmed(nameField)
        let email = Self.trimmed(emailField)
        isSaving = true
        updateControls()
        Task { [weak self] in
            do {
                try await ApelinService.app.gitAuthorSet(
                    name: name.isEmpty ? nil : name,
                    email: email.isEmpty ? nil : email,
                )
                guard let self else { return }
                settings?.authorName = name.isEmpty ? nil : name
                settings?.authorEmail = email.isEmpty ? nil : email
                nameField.text = name
                emailField.text = email
                SPIndicator.present(title: String(localized: "Saved"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Save Author", message: error.readableMessage)
            }
            self?.isSaving = false
            self?.updateControls()
        }
    }

    // MARK: - Credentials

    private func addCredential() {
        navigationController?.pushViewController(GitCredentialController(), animated: true)
    }

    private func confirmRemoval(_ credential: GitCredentialSummary) {
        presentConfirmation(
            title: "Remove Credential for \(credential.host)?",
            message: "Git can no longer sign in to this host until you add a credential for it again.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove(credential)
        }
    }

    private func remove(_ credential: GitCredentialSummary) {
        Task { [weak self] in
            do {
                try await ApelinService.app.gitCredentialRemove(host: credential.host)
                SPIndicator.present(title: String(localized: "Removed"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Remove Credential", message: error.readableMessage)
            }
            self?.load()
        }
    }

    // MARK: - Table

    private func configure(_ field: UITextField, label: String, placeholder: String) {
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = label
        field.placeholder = placeholder
        field.addAction(UIAction { [weak self] _ in self?.updateControls() }, for: .editingChanged)
    }

    /// A field filling the row's margins; the field is the element, not the row.
    static func cell(containing field: UITextField) -> UITableViewCell {
        UITableViewCell(style: .default, reuseIdentifier: nil).then { cell in
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(field)
            let margins = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
                field.topAnchor.constraint(equalTo: margins.topAnchor),
                field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
                cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])
        }
    }

    private func cell(for row: Row) -> UITableViewCell? {
        switch row {
        case .name:
            return nameCell
        case .email:
            return emailCell
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = String(localized: "Git Settings Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel
            content.textToSecondaryTextVerticalPadding = 4
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .credential(credential):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            var content = UIListContentConfiguration.valueCell()
            content.text = credential.host
            content.secondaryText = credential.username
            content.textProperties.numberOfLines = 1
            content.secondaryTextProperties.numberOfLines = 1
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .add:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Add Credential…")
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityTraits.insert(.button)
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.value(at: indexPath) == .add
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if dataSource.value(at: indexPath) == .add {
            addCredential()
        }
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        if case .credential = dataSource.value(at: indexPath) {
            return .delete
        }
        return .none
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard case let .credential(credential)? = dataSource.value(at: indexPath) else { return nil }
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "Remove"),
        ) { [weak self] _, _, completion in
            // the row goes when the host says it has
            completion(false)
            self?.confirmRemoval(credential)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }
}
