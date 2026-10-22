import ApelinCore
import ApelinProtocol
import CryptoKit
import Then
import UIKit

/// One release build for one distribution target, started as the page
/// opens: its stages while it runs, then Export Package for the one
/// `.deb` it made, or Retry. The `…` menu holds the build's whole log.
@MainActor
final class DistributionBuildController: TableController {
    private enum Stage: Int, CaseIterable {
        case preparing, compiling, packaging, verifying

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing")
            case .compiling: String(localized: "Compiling")
            case .packaging: String(localized: "Packaging")
            case .verifying: String(localized: "Verifying")
            }
        }

        init(event: String) {
            switch event {
            case "check": self = .preparing
            case "package": self = .packaging
            case "verify": self = .verifying
            default: self = .compiling
            }
        }
    }

    private enum Section: Hashable {
        case progress, outcome
    }

    private enum Row: Hashable {
        case stage(Stage), outcome
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var complete = false
        var active = false
    }

    private let projectName: String
    private let target: BuildBootstrap
    private var stage = Stage.preparing
    private var artifact: BuildArtifact?
    private var work: Task<Void, Never>?
    private var outcome: String?
    private var logLines: [String] = []
    private weak var logPage: TaskLogController?
    private var dataSource: TableDataSource<Section, Row, RowContent>!
    private lazy var exportButton = UIBarButtonItem(
        title: String(localized: "Export Package"),
        primaryAction: UIAction { [weak self] _ in self?.exportPackage() },
    )
    private lazy var moreButton = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [
            UIAction(
                title: String(localized: "Build Log"),
                image: UIImage(systemName: "doc.plaintext"),
            ) { [weak self] _ in
                self?.openLog()
            },
        ]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    init(projectName: String, target: BuildBootstrap) {
        self.projectName = projectName
        self.target = target
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:target:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = target.rawValue
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Build")
        dataSource = TableDataSource(
            tableView: tableView,
            identifier: { $0.row },
        ) { [weak self] tableView, indexPath, content in
            let cell = tableView.dequeueReusableCell(withIdentifier: "Build", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            section == .progress ? String(localized: "Release Build") : nil
        }
        start()
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content = UIListContentConfiguration.cell()
        content.text = value.text
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityValue = nil
        switch value.row {
        case .stage:
            content.image = UIImage(systemName: value.complete ? "checkmark.circle.fill" : "circle")
            content.imageProperties.tintColor = value.complete ? .systemGreen : .tertiaryLabel
            if value.active {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            cell.accessibilityValue = value.complete
                ? String(localized: "Completed")
                : value.active ? String(localized: "In Progress") : String(localized: "Waiting")
        case .outcome:
            content.textProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
    }

    private func updateRows() {
        var sections: [(Section, [RowContent])] = [
            (.progress, Stage.allCases.map { item in
                RowContent(
                    row: .stage(item),
                    text: item.title,
                    complete: artifact != nil || item.rawValue < stage.rawValue,
                    active: work != nil && item == stage,
                )
            }),
        ]
        if let outcome {
            sections.append((.outcome, [RowContent(row: .outcome, text: outcome)]))
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func updateNavigation() {
        let running = work != nil
        navigationController?.isModalInPresentation = running
        navigationItem.hidesBackButton = running
        let primary: UIBarButtonItem
        if running {
            primary = UIBarButtonItem(
                title: String(localized: "Stop"),
                primaryAction: UIAction { [weak self] _ in self?.work?.cancel() },
            )
        } else if artifact != nil {
            exportButton.isEnabled = true
            primary = exportButton
        } else {
            primary = UIBarButtonItem(
                title: String(localized: "Retry"),
                primaryAction: UIAction { [weak self] _ in self?.start() },
            )
        }
        // the right bar's items run from the trailing edge in
        navigationItem.rightBarButtonItems = [primary, moreButton]
    }

    // MARK: - The build

    private func start() {
        guard work == nil else { return }
        artifact = nil
        outcome = nil
        stage = .preparing
        logLines = []
        logPage?.update(logLines)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await DistributionProject.id(named: projectName)
                try Task.checkCancellation()
                artifact = try await build(projectID: id)
                outcome = String(localized: "The package is ready to export.")
            } catch is CancellationError {
                outcome = String(localized: "Distribution stopped. You can try again.")
            } catch {
                outcome = error.readableMessage
            }
            work = nil
            updateNavigation()
            updateRows()
        }
        updateNavigation()
        updateRows()
    }

    private func build(projectID: String) async throws -> BuildArtifact {
        let handle = try await ApelinService.app.buildStart(
            projectID: projectID,
            configuration: .release,
            bootstrap: target,
        )
        return try await withTaskCancellationHandler {
            var artifact: BuildArtifact?
            var succeeded = false
            var failure: String?
            for try await event in ApelinService.app.events(of: handle) {
                try Task.checkCancellation()
                record(event)
                if event.kind == "stage", let name = event.payload?["stage"]?.stringValue {
                    let next = Stage(event: name)
                    if next != stage {
                        stage = next
                        updateRows()
                    }
                } else if event.kind == "artifact" {
                    artifact = try event.payload?.decode(BuildArtifact.self)
                } else if event.kind == TaskEvent.stateKind {
                    succeeded = event.payload?["state"]?.stringValue == TaskState.succeeded.rawValue
                    failure = event.payload?["message"]?.stringValue
                }
            }
            try Task.checkCancellation()
            guard succeeded, let artifact, artifact.bootstrap == target.rawValue else {
                throw ApelinError(
                    .internal,
                    failure ?? String(localized: "The package could not be built. Check the project's build description and try again."),
                )
            }
            return artifact
        } onCancel: {
            Task { try? await ApelinService.app.buildCancel(taskID: handle.taskID) }
        }
    }

    /// The build's own words for the log: its stages, log lines and
    /// diagnostics, and how it ended.
    private func record(_ event: TaskEvent) {
        let line: String? = switch event.kind {
        case "stage": event.payload?["stage"]?.stringValue.map { "▸ " + $0 }
        case "log": event.payload?["line"]?.stringValue
        case "diagnostic": event.payload?["message"]?.stringValue
        case TaskEvent.stateKind:
            [event.payload?["state"]?.stringValue, event.payload?["message"]?.stringValue]
                .compactMap(\.self).joined(separator: ": ")
        default: nil
        }
        guard let line else { return }
        logLines.append(line)
        logPage?.update(logLines)
    }

    private func openLog() {
        let page = TaskLogController(lines: logLines)
        logPage = page
        navigationController?.pushViewController(page, animated: true)
    }

    private func exportPackage() {
        guard let artifact, artifact.bootstrap == target.rawValue, exportButton.isEnabled else { return }
        exportButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { exportButton.isEnabled = true }
            do {
                let url = try await Task.detached {
                    guard let path = artifact.path, let canonical = CanonicalPath.resolve(path),
                          let builds = CanonicalPath.resolve(DataFolder.app.root.appendingPathComponent("Builds").path),
                          CanonicalPath.isCanonical(canonical, inside: builds)
                    else {
                        throw ApelinError(
                            .notFound,
                            String(localized: "The package is no longer available. Build it again."),
                        )
                    }
                    let url = URL(fileURLWithPath: canonical)
                    let digest = try "sha256:"
                        + SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                    guard digest == artifact.digest else {
                        throw ApelinError(.conflict, String(localized: "The package changed after it was built. Build it again before exporting."))
                    }
                    return url
                }.value
                guard self.artifact == artifact else { return }
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.popoverPresentationController?.barButtonItem = exportButton
                present(sheet, animated: true)
            } catch {
                guard self.artifact == artifact else { return }
                presentNotice(title: "Unable to Export", message: error.readableMessage)
            }
        }
    }
}
