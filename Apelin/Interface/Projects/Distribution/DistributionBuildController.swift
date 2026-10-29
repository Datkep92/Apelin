import ApelinCore
import ApelinProtocol
import CryptoKit
import Then
import UIKit

/// One release build for one distribution target, started as the page
/// opens: its stages while it runs, then Export Package for the one
/// `.deb` it made, or Retry. A workspace's build runs its own script, and
/// what the build finds in the package it wrote (a placeholder identifier,
/// a version packaged before, another package for the other target) is
/// listed under the outcome. The `…` menu holds the build's whole log and,
/// once the package is ready, Publish, which adds it to the linked package
/// repository (Settings ▸ Git ▸ Publishing) and pushes it.
@MainActor
final class DistributionBuildController: TableController {
    private enum Stage: Int {
        case preparing, compiling, running, packaging, verifying, readyToExport

        /// apelin-build's own stages, or a workspace's script's
        /// (`ExternalBuild`: `script`, then `verify`).
        static func stages(for method: ProjectBuildMethod) -> [Stage] {
            method == .script ? [.preparing, .running, .verifying, .readyToExport] : [.preparing, .compiling, .packaging, .verifying, .readyToExport]
        }

        var title: String {
            switch self {
            case .preparing: String(localized: "Preparing")
            case .compiling: String(localized: "Compiling")
            case .running: String(localized: "Running Build Script")
            case .packaging: String(localized: "Packaging")
            case .verifying: String(localized: "Verifying Package")
            case .readyToExport: String(localized: "Ready to Export")
            }
        }

        init(event: String) {
            switch event {
            case "check": self = .preparing
            case "script": self = .running
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
        case stage(Stage), outcome, finding(Int)
    }

    private struct RowContent: Equatable {
        var row: Row
        var text: String?
        var secondaryText: String?
    }

    private let projectName: String
    private let target: BuildBootstrap
    private let method: ProjectBuildMethod
    private var stage = Stage.preparing
    private var artifact: BuildArtifact?
    /// The build's `distribution.*` warnings about the package it wrote.
    private var findings: [ProjectDiagnostic] = []
    private var work: Task<Void, Never>?
    private var outcome: String?
    private var finishedState: TaskState?
    private lazy var stepCells = Dictionary(uniqueKeysWithValues: Stage.stages(for: method).map { ($0, TaskStepCell(stage: String($0.rawValue))) })
    private var logLines: [String] = []
    private weak var logPage: TaskLogController?
    private var dataSource: TableDataSource<Section, Row, RowContent>!
    private lazy var exportButton = UIBarButtonItem(
        title: String(localized: "Export"),
        primaryAction: UIAction { [weak self] _ in self?.exportPackage() },
    )
    private lazy var moreButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu)
        .then { $0.accessibilityLabel = String(localized: "More") }

    /// The log always; Publish once there is a package.
    private var moreMenu: UIMenu {
        var items = [
            UIAction(title: String(localized: "Build Log"), image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in
                self?.openLog()
            },
        ]
        if artifact != nil, work == nil {
            items.append(UIAction(
                title: String(localized: "Publish…"),
                image: UIImage(systemName: "shippingbox"),
            ) { [weak self] _ in
                self?.publish()
            })
        }
        return UIMenu(children: items)
    }

    init(projectName: String, target: BuildBootstrap, method: ProjectBuildMethod) {
        self.projectName = projectName
        self.target = target
        self.method = method
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(projectName:target:method:)")
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
            if case let .stage(stage) = content.row {
                return self?.stepCells[stage]
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Build", for: indexPath)
            self?.configure(cell, value: content)
            return cell
        }
        dataSource.headerTitle = { section in
            section == .progress ? String(localized: "Steps") : nil
        }
        start()
    }

    // MARK: - Rows

    private func configure(_ cell: UITableViewCell, value: RowContent) {
        var content: UIListContentConfiguration = switch value.row {
        case .finding: .explanatoryCell()
        default: .stackedValueCell()
        }
        content.text = value.text
        content.secondaryText = value.secondaryText
        content.secondaryTextProperties.color = .secondaryLabel
        cell.accessoryView = nil
        cell.selectionStyle = .none
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .staticText
        cell.accessibilityValue = nil
        switch value.row {
        case .stage:
            break
        case .outcome:
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
            if finishedState == .failed || finishedState == .cancelled {
                content.image = UIImage(systemName: finishedState == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill")
                content.imageProperties.tintColor = finishedState == .cancelled ? .secondaryLabel : .systemRed
            }
        case .finding:
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
            content.textProperties.numberOfLines = 0
            content.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = [value.text, value.secondaryText].compactMap(\.self).joined(separator: ", ")
    }

    private func updateRows() {
        for item in Stage.stages(for: method) {
            let state: EnvironmentTaskProgress.StageState = if finishedState == .succeeded || item.rawValue < stage.rawValue {
                .done
            } else if item == stage {
                finishedState == nil ? .running(nil) : .failed
            } else {
                .pending
            }
            let status: String = switch state {
            case .done: String(localized: "Completed")
            case .running: String(localized: "In Progress")
            case .failed: finishedState == .cancelled ? String(localized: "Stopped") : String(localized: "Failed")
            default: finishedState == nil ? String(localized: "Waiting") : String(localized: "Not Started")
            }
            stepCells[item]?.show(state, status: status, animated: tableView.window != nil && !UIAccessibility.isReduceMotionEnabled, title: item.title)
        }
        var sections: [(Section, [RowContent])] = [
            (.progress, Stage.stages(for: method).map { item in
                RowContent(
                    row: .stage(item),
                    text: item.title,
                )
            }),
        ]
        if let outcome {
            let title = switch finishedState {
            case .succeeded: String(localized: "Completed")
            case .cancelled: String(localized: "Stopped")
            default: String(localized: "Failed")
            }
            var rows: [RowContent] = finishedState == .succeeded ? [] : [RowContent(row: .outcome, text: title, secondaryText: EnvironmentTaskProgress.readableDetail(outcome))]
            rows += findings.indices.map { index in
                RowContent(
                    row: .finding(index),
                    text: DistributionAdvice.title(of: findings[index]),
                    secondaryText: DistributionAdvice.advice(for: findings[index]),
                )
            }
            if !rows.isEmpty {
                sections.append((.outcome, rows))
            }
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
        moreButton.menu = moreMenu
        // the right bar's items run from the trailing edge in
        navigationItem.rightBarButtonItems = [primary, moreButton]
    }

    // MARK: - The build

    private func start() {
        guard work == nil else { return }
        artifact = nil
        outcome = nil
        finishedState = nil
        findings = []
        stage = .preparing
        logLines = []
        logPage?.update(logLines)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await DistributionProject.id(named: projectName)
                try Task.checkCancellation()
                artifact = try await build(projectID: id)
                finishedState = .succeeded
                outcome = String(localized: "The package is ready to export.")
                StarPrompt.buildsCompleted(1, from: self)
            } catch is CancellationError {
                finishedState = .cancelled
                outcome = String(localized: "Distribution stopped. You can try again.")
            } catch {
                finishedState = .failed
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
                } else if event.kind == "diagnostic",
                          let finding = try? event.payload?.decode(ProjectDiagnostic.self),
                          finding.code.hasPrefix("distribution.")
                {
                    findings.append(finding)
                } else if event.kind == TaskEvent.stateKind {
                    succeeded = event.payload?["state"]?.stringValue == TaskState.succeeded.rawValue
                    failure = event.payload?["message"]?.stringValue
                }
            }
            try Task.checkCancellation()
            guard succeeded, let artifact, artifact.bootstrap == target.rawValue else {
                throw ApelinError(
                    .internal,
                    failure ?? (method == .script
                        ? String(localized: "The package could not be built. Check the build script’s log and try again.")
                        : String(localized: "The package could not be built. Check the project’s build description and try again.")),
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

    /// The build's package where the build left it, with the bytes it
    /// recorded; read off the main thread.
    private static func verifiedPackage(_ artifact: BuildArtifact) async throws -> URL {
        try await Task.detached {
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
    }

    private func exportPackage() {
        guard let artifact, artifact.bootstrap == target.rawValue, exportButton.isEnabled else { return }
        exportButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { exportButton.isEnabled = true }
            do {
                let url = try await Self.verifiedPackage(artifact)
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

    /// The package into the linked package repository: checked as an export
    /// is, confirmed with where it goes, then followed as a task.
    private func publish() {
        guard let artifact, artifact.bootstrap == target.rawValue, work == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await Self.verifiedPackage(artifact)
                guard let linked = try await ApelinService.app.distributionRepositoryList(repositories: false).linked else {
                    presentNotice(
                        title: "No Package Repository",
                        message: "Create or link one in Settings ▸ Git ▸ Publishing first.",
                    )
                    return
                }
                presentConfirmation(
                    title: "Publish to \(linked.fullName)?",
                    message: "The package is added to the repository’s debs folder, committed and pushed. Devices with \(linked.sourceURL) see it within a few minutes.",
                    confirmTitle: "Publish",
                ) { [weak self] in
                    self?.startPublishing(url)
                }
            } catch {
                presentNotice(title: "Unable to Publish", message: error.readableMessage)
            }
        }
    }

    private func startPublishing(_ package: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let handle = try await ApelinService.app.distributionPublish(files: [package.path])
                let page = EnvironmentTaskController(
                    handle: handle,
                    work: .distributionPublish,
                    title: String(localized: "Publishing Package"),
                    doneTitle: String(localized: "Published"),
                )
                navigationController?.pushViewController(page, animated: true)
            } catch {
                presentNotice(title: "Unable to Publish", message: error.readableMessage)
            }
        }
    }
}
