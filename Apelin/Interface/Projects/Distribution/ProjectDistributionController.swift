import ApelinCore
import ApelinProtocol
import UIKit

/// The first step of distributing a project: pick the target, see what the
/// package should not carry yet, then build on its own page
/// (`DistributionBuildController`). What the check finds is advice: Build
/// still goes ahead after a confirmation, and Ask Agent to Prepare hands
/// the work to the project's conversation. What stops the build — an error
/// the check finds, such as a workspace script that is not in the project —
/// is listed and Build waits for it to be fixed. A workspace is built by
/// its own script, whose package is checked once it is written. A project
/// with no build description or script (`ProjectBuildMethod`) has nothing
/// to package: the page says so and offers no target.
@MainActor
final class ProjectDistributionController: TableController {
    private enum Section: Hashable {
        case project, target, readiness
    }

    private enum Row: Hashable {
        case project, target(BuildBootstrap), checking, ready, blocker(Int), issue(Int), prepare, unavailable
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
    /// Nil until the manifest is read; one that cannot build takes the
    /// targets away.
    private var method: ProjectBuildMethod?
    /// The check's errors: the build would stop at them.
    private var blockers: [ProjectDiagnostic] = []
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
                self?.blockers.isEmpty == false
                    ? String(localized: "Fix these before building.")
                    : self?.issues.isEmpty == false
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
        case .blocker:
            content.image = UIImage(systemName: "xmark.octagon.fill")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.numberOfLines = 0
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
        let canBuild = method?.canBuild ?? true
        var readiness: [RowContent]
        if let blocker = method?.blocker {
            readiness = [RowContent(row: .unavailable, text: blocker)]
        } else if checking {
            readiness = [RowContent(row: .checking, text: String(localized: "Checking…"))]
        } else if let checkFailure {
            readiness = [RowContent(row: .unavailable, text: checkFailure)]
        } else if blockers.isEmpty, issues.isEmpty {
            readiness = [RowContent(
                row: .ready,
                text: String(localized: "Ready to distribute"),
                secondaryText: method == .script
                    ? String(localized: "The package is checked after the build script writes it.")
                    : nil,
            )]
        } else {
            readiness = blockers.indices.map { index in
                RowContent(row: .blocker(index), text: blockers[index].message)
            }
            readiness += issues.indices.map { index in
                RowContent(
                    row: .issue(index),
                    text: DistributionAdvice.title(of: issues[index]),
                    secondaryText: DistributionAdvice.advice(for: issues[index]),
                )
            }
            if onPrepare != nil {
                readiness.append(RowContent(row: .prepare, text: String(localized: "Ask Agent to Prepare")))
            }
        }
        var sections: [(Section, [RowContent])] = [
            (.project, [RowContent(row: .project, text: displayName ?? projectName)]),
        ]
        if canBuild {
            sections.append((.target, BuildBootstrap.allCases.map { target in
                RowContent(row: .target(target), text: target.rawValue, selected: target == selectedTarget)
            }))
        }
        sections.append((.readiness, readiness))
        dataSource.update(sections, reconfigure: true)
        navigationItem.rightBarButtonItem?.isEnabled = canBuild && blockers.isEmpty && !checking
            && checkFailure == nil && selectedTarget != nil
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
                let project = try await DistributionProject.resolve(named: projectName)
                guard !Task.isCancelled else { return }
                method = project.method
                guard project.method.canBuild else {
                    selectedTarget = nil
                    blockers = []
                    issues = []
                    checking = false
                    updateRows()
                    return
                }
                let response = try await ApelinService.app.projectCheck(
                    projectID: project.id,
                    purpose: .distribution,
                    bootstrap: target,
                )
                guard !Task.isCancelled else { return }
                blockers = response.diagnostics.filter { $0.severity == .error }
                issues = response.diagnostics.filter { $0.code.hasPrefix("distribution.") && $0.severity != .error }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                blockers = []
                issues = []
                checkFailure = error.readableMessage
            }
            checking = false
            updateRows()
        }
    }

    // MARK: - Actions

    private func build() {
        guard let target = selectedTarget, let method, method.canBuild, blockers.isEmpty else { return }
        let open = { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(
                DistributionBuildController(projectName: projectName, target: target, method: method),
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
        let prompt = if method == .script {
            String(localized: "Prepare this workspace for distribution: run apelin_project_check_distribution and fix everything it lists, and make sure its build script writes a release package for each target when APELIN_CONFIGURATION is release, with the package's real name, identifier, author and a new version. Then tell me what you changed. Do not build yet.")
        } else if let target = selectedTarget {
            String(localized: "Prepare this project for distribution to \(target.rawValue): run apelin_project_check_distribution, fix everything it lists (the package's name, description, author and version, its identifiers, and the app's icon if it has one), then tell me what you changed. Do not build yet.")
        } else {
            String(localized: "Prepare this project for distribution: run apelin_project_check_distribution, fix everything it lists (the package's name, description, author and version, its identifiers, and the app's icon if it has one), then tell me what you changed. Do not build yet.")
        }
        dismiss(animated: true) { onPrepare(prompt) }
    }
}

/// The project folder's identity, read from its own manifest after the
/// folder is resolved inside `Projects/`.
enum DistributionProject {
    /// The project's ID; throws for one with nothing to build its package
    /// from, saying what it needs.
    static func id(named name: String) async throws -> String {
        let project = try await resolve(named: name)
        if let blocker = project.method.blocker {
            throw ApelinError(.badRequest, blocker)
        }
        return project.id
    }

    /// The project's ID and how its package is built (`ProjectBuildMethod`).
    static func resolve(named name: String) async throws -> (id: String, method: ProjectBuildMethod) {
        try await Task.detached { () throws -> (id: String, method: ProjectBuildMethod) in
            guard let root = DataFolder.app.project(named: name), let canonical = CanonicalPath.resolve(root.path),
                  let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
                  canonical == projects + "/" + name,
                  let manifest = CanonicalPath.resolve(root.appendingPathComponent("apelin-project.json").path),
                  manifest == canonical + "/apelin-project.json"
            else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            let value = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            guard let id = value["projectID"]?.stringValue else {
                throw ApelinError(.notFound, String(localized: "This project is no longer available."))
            }
            return (id, ProjectBuildMethod(manifest: value))
        }.value
    }
}
