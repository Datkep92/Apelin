import ApelinCore
import ApelinProtocol
import UIKit

/// The first step of distributing a project: pick the target, see what the
/// package should not carry yet, then build on its own page
/// (`DistributionBuildController`). What the check finds is advice: Build
/// still goes ahead after a confirmation, and Ask Agent to Prepare hands
/// the work to the project's conversation. A project with no build
/// description (`ProjectBuildDescription`) has nothing to package: the page
/// says so and offers no target.
@MainActor
final class ProjectDistributionController: TableController {
    private enum Section: Hashable {
        case project, target, readiness
    }

    private enum Row: Hashable {
        case project, target(BuildBootstrap), checking, ready, issue(Int), prepare, unavailable
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
        var selected = false
    }

    private let projectName: String
    /// Asks the project's conversation to prepare the package; nil where
    /// the page was not opened from one.
    private let onPrepare: ((String) -> Void)?
    private var displayName: String?
    private var selectedTarget: BuildBootstrap?
    /// False once the check finds no build description; the targets go.
    private var hasBuildDescription = true
    private var issues: [ProjectDiagnostic] = []
    private var checking = false
    private var checkFailure: String?
    private var check: Task<Void, Never>?
    private var hasAppeared = false
    private var dataSource: TableDataSource<Section, Row, RowContent>!

    init(projectName: String, onPrepare: ((String) -> Void)? = nil) {
        self.projectName = projectName
        self.onPrepare = onPrepare
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:onPrepare:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Distribute Project")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Build"),
            primaryAction: UIAction { [weak self] _ in self?.build() },
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Distribution")
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            let cell = tableView.dequeueReusableCell(withIdentifier: "Distribution", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            switch section {
            case .project: String(localized: "Project")
            case .target: String(localized: "Target")
            case .readiness: String(localized: "Before Distributing")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .target: String(localized: "Choose one target, then tap Build. To build the other target, come back and build again.")
            case .readiness:
                self?.issues.isEmpty == false
                    ? String(localized: "These are suggestions. You can still build the package.")
                    : nil
            case .project: nil
            }
        }
        updateRows()
        refreshCheck()
        Task { [weak self] in
            guard let self else { return }
            displayName = await (try? ProjectSummary.load())?.first { $0.name == self.projectName }?.displayTitle
            updateRows()
        }
    }

    /// A project changed while the build page was open is checked again
    /// on the way back.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared {
            refreshCheck()
        }
        hasAppeared = true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .target(target) where target != selectedTarget:
            selectedTarget = target
            updateRows()
            refreshCheck()
        case .prepare:
            prepare()
        default:
            break
        }
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        switch value.row {
        case .project:
            break
        case .target:
            cell.accessoryType = value.selected ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityTraits = value.selected ? [.button, .selected] : .button
        case .checking:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        case .ready:
            content.image = UIImage(systemName: "checkmark.seal.fill")
            content.imageProperties.tintColor = .systemGreen
        case .issue:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        case .prepare:
            content.textProperties.color = .tintColor
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .unavailable:
            content.textProperties.numberOfLines = 0
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
    }

    private func updateRows() {
        var readiness: [RowContent]
        if !hasBuildDescription {
            readiness = [RowContent(row: .unavailable, text: DistributionProject.missingBuildDescription)]
        } else if checking {
            readiness = [RowContent(row: .checking, text: String(localized: "Checking…"))]
        } else if let checkFailure {
            readiness = [RowContent(row: .unavailable, text: checkFailure)]
        } else if issues.isEmpty {
            readiness = [RowContent(row: .ready, text: String(localized: "Ready to distribute"))]
        } else {
            readiness = issues.indices.map { index in
                RowContent(
                    row: .issue(index),
                    text: Self.title(of: issues[index]),
                    secondaryText: Self.advice(for: issues[index]),
                )
            }
            if onPrepare != nil {
                readiness.append(RowContent(row: .prepare, text: String(localized: "Ask Agent to Prepare")))
            }
        }
        var sections: [(Section, [RowContent])] = [
            (.project, [RowContent(row: .project, text: displayName ?? projectName)]),
        ]
        if hasBuildDescription {
            sections.append((.target, BuildBootstrap.allCases.map { target in
                RowContent(row: .target(target), text: target.rawValue, selected: target == selectedTarget)
            }))
        }
        sections.append((.readiness, readiness))
        dataSource.update(sections, reconfigure: true)
        navigationItem.rightBarButtonItem?.isEnabled = hasBuildDescription && selectedTarget != nil
    }

    // MARK: - The check

    /// The distribution check for the chosen target (any, before one is
    /// chosen); a newer one replaces a check still running.
    private func refreshCheck() {
        check?.cancel()
        dataSource.beginLoad()
        checking = true
        checkFailure = nil
        updateRows()
        let target = selectedTarget
        check = Task { [weak self] in
            guard let self else { return }
            do {
                guard let id = try await DistributionProject.buildableID(named: projectName) else {
                    guard !Task.isCancelled else { return }
                    hasBuildDescription = false
                    selectedTarget = nil
                    issues = []
                    checking = false
                    updateRows()
                    return
                }
                hasBuildDescription = true
                let response = try await ApelinService.app.projectCheck(
                    projectID: id,
                    purpose: .distribution,
                    bootstrap: target,
                )
                guard !Task.isCancelled else { return }
                issues = response.diagnostics.filter { $0.code.hasPrefix("distribution.") }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                issues = []
                checkFailure = error.readableMessage
            }
            checking = false
            updateRows()
        }
    }

    /// What the finding is, in the reader's words.
    private static func title(of issue: ProjectDiagnostic) -> String {
        switch issue.code {
        case "distribution.package.name.template": String(localized: "The package still uses the template's name")
        case "distribution.package.description.template":
            String(localized: "The package still uses the template's description")
        case "distribution.package.author.template": String(localized: "The package still uses the template's author")
        case "distribution.package.version.template":
            String(localized: "The package still uses the template's initial version")
        case "distribution.package.id.local": String(localized: "The package uses a placeholder identifier")
        case "distribution.bundleID.local": String(localized: "The app uses a placeholder bundle identifier")
        case "distribution.icon.missing": String(localized: "The app has no icon")
        case "distribution.version.packaged": String(localized: "This version was already packaged")
        default: issue.message
        }
    }

    /// What to change; nil for a finding the app does not know, whose
    /// message is already its title.
    private static func advice(for issue: ProjectDiagnostic) -> String? {
        switch issue.code {
        case "distribution.package.name.template":
            String(localized: "Give it the name people will see in their package manager.")
        case "distribution.package.description.template": String(localized: "Describe what the package does.")
        case "distribution.package.author.template": String(localized: "Add the author's name.")
        case "distribution.package.version.template": String(localized: "Give the first release its own version.")
        case "distribution.package.id.local", "distribution.bundleID.local":
            String(localized: "Use a reverse-DNS identifier you own.")
        case "distribution.icon.missing": String(localized: "The Home Screen and package managers show a blank icon.")
        case "distribution.version.packaged": String(localized: "Raise the version if anything changed, or package managers will not offer the new build as an update.")
        default: nil
        }
    }

    // MARK: - Actions

    private func build() {
        guard let target = selectedTarget else { return }
        let open = { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(
                DistributionBuildController(projectName: projectName, target: target),
                animated: true,
            )
        }
        guard !issues.isEmpty else {
            open()
            return
        }
        presentConfirmation(
            title: "Build Anyway?",
            message: "Some details still need attention before other people install this package.",
            confirmTitle: "Build",
            onConfirm: open,
        )
    }

    private func prepare() {
        guard let onPrepare else { return }
        let prompt = if let target = selectedTarget {
            String(localized: "Prepare this project for distribution to \(target.rawValue): run check_distribution, fix everything it lists (the package's name, description, author and version, its identifiers, and the app's icon if it has one), then tell me what you changed. Do not build yet.")
        } else {
            String(localized: "Prepare this project for distribution: run check_distribution, fix everything it lists (the package's name, description, author and version, its identifiers, and the app's icon if it has one), then tell me what you changed. Do not build yet.")
        }
        dismiss(animated: true) { onPrepare(prompt) }
    }
}

/// The project folder's identity, read from its own manifest after the
/// folder is resolved inside `Projects/`.
enum DistributionProject {
    static var missingBuildDescription: String {
        String(localized: "This project needs a build description before it can be distributed. Ask your agent to add one.")
    }

    /// The project's ID; throws for one with no build description.
    static func id(named name: String) async throws -> String {
        guard let id = try await buildableID(named: name) else {
            throw ApelinError(.badRequest, missingBuildDescription)
        }
        return id
    }

    /// The project's ID, or nil when it has no build description
    /// (`ProjectBuildDescription`) and so nothing to distribute.
    static func buildableID(named name: String) async throws -> String? {
        try await Task.detached { () throws -> String? in
            guard let root = DataFolder.app.project(named: name), let canonical = CanonicalPath.resolve(root.path),
                  let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
                  canonical == projects + "/" + name,
                  let manifest = CanonicalPath.resolve(root.appendingPathComponent("apelin-project.json").path),
                  manifest == canonical + "/apelin-project.json"
            else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let value = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            guard ProjectBuildDescription.isPresent(in: value) else { return nil }
            guard let id = value["projectID"]?.stringValue else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            return id
        }.value
    }
}
