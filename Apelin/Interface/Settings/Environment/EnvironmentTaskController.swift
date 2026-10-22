import ApelinCore
import ApelinProtocol
import SnapKit
import Then
import UIKit

/// One environment task followed to its end, laid out as Irisin's install
/// page: a row per stage, the line under its name saying what it is doing
/// and a ring at the trailing edge counting it, a checkmark once it is done.
/// The bar carries a spinner while the task runs — Continue in Background
/// instead at the root of a sheet of its own — and a checkmark once it has
/// ended; the title says how it ended, and a failure's reason and any
/// warnings close the list, the task's ID in small grey under it. The menu
/// opens the full log and stops the task.
///
/// The session host owns the task, not this page: leaving it, or the app,
/// stops nothing, and the page opened again replays the task from its first
/// event. Stop, in the menu, is what ends it.
final class EnvironmentTaskController: TableController {
    /// Told once, when the task has ended, so the page beneath reads its
    /// list again.
    var onFinish: (() -> Void)?

    private enum Section: Hashable {
        case stages
        case outcome
        case warnings
    }

    private enum Row: Equatable {
        case stage(String)
        case outcome(String?, String?, TaskState)
        case warning(String, occurrence: Int)
        var id: String {
            switch self {
            case let .stage(stage): "stage:" + stage
            case .outcome: "outcome"
            case let .warning(text, occurrence): "warning:\(occurrence):" + text
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let handle: TaskHandle
    private let runningTitle: String
    private let doneTitle: String
    private var progress: EnvironmentTaskProgress
    private var follower: Task<Void, Never>?
    private var cancelRequested = false

    /// One cell per stage, kept rather than dequeued, so a ring goes on
    /// turning from one event to the next.
    private var stageCells: [StageCell] = []

    /// Every event as a line, for the full log; a download's progress is
    /// one line said again with new figures, not a line per sample.
    private var logLines: [String] = []
    private var lastLogKey: String?
    private weak var logPage: TaskLogController?

    private static let logTime = DateFormatter().then {
        $0.dateFormat = "HH:mm:ss"
    }

    /// `doneTitle` is the page's title once the task succeeded:
    /// "Toolchain Ready", "SDK Imported".
    init(handle: TaskHandle, work: EnvironmentTaskProgress.Work, title: String, doneTitle: String) {
        self.handle = handle
        runningTitle = title
        self.doneTitle = doneTitle
        progress = EnvironmentTaskProgress(work: work)
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(handle:work:title:doneTitle:)")
    }

    deinit {
        follower?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.backButtonDisplayMode = .minimal
        tableView.allowsSelection = false
        tableView.tableFooterView = TableFootnoteView(lines: [handle.taskID.rawValue])
        dataSource.headerTitle = { $0 == .warnings ? String(localized: "Warnings") : nil }
        render()
        follow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (tableView.tableFooterView as? TableFootnoteView)?.fit(in: tableView)
    }

    // MARK: - Following

    /// Replays the task from its first event and reads on until it ends.
    /// A dropped connection is the same call again from the last event: the
    /// stream ends with an error, and the next attach picks up after it. A
    /// task the host does not have, or will not show, ends the page.
    private func follow() {
        follower = Task { [weak self, handle] in
            var cursor = EventSeq.start
            while !Task.isCancelled {
                do {
                    for try await event in ApelinService.app.events(of: handle, afterSeq: cursor) {
                        cursor = event.seq
                        self?.receive(event)
                    }
                    return
                } catch {
                    if Task.isCancelled {
                        return
                    }
                    if let error = error as? ApelinError, error.code.endsTaskFollowing {
                        self?.lose(error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    private func receive(_ event: TaskEvent) {
        let wasFinished = progress.isFinished
        log(event)
        progress.apply(event)
        render()
        if progress.isFinished, !wasFinished {
            finished()
        }
    }

    /// `12:04:31  progress  {"completed":…}`: the time, the kind and what
    /// it carried, as the host wrote it.
    private func log(_ event: TaskEvent) {
        var line = Self.logTime.string(from: event.time) + "  " + event.kind
        if let payload = event.payload,
           let data = try? JSONEncoder().then({
               $0.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
           }).encode(payload),
           let text = String(data: data, encoding: .utf8)
        {
            line += "  " + text
        }
        let key = event.kind == "progress"
            ? "progress " + (event.payload?["stage"]?.stringValue ?? "")
            + " " + (event.payload?["phase"]?.stringValue ?? "")
            : nil
        if let key, key == lastLogKey, !logLines.isEmpty {
            logLines[logLines.count - 1] = line
        } else {
            logLines.append(line)
        }
        lastLogKey = key
        logPage?.update(logLines)
    }

    private func openLog() {
        let page = TaskLogController(lines: logLines)
        logPage = page
        navigationController?.pushViewController(page, animated: true)
    }

    private func lose(_ error: Error) {
        guard !progress.isFinished else { return }
        progress.lost(error.readableMessage)
        render()
        finished()
    }

    private func finished() {
        onFinish?()
        onFinish = nil
        UIAccessibility.post(notification: .announcement, argument: title)
    }

    // MARK: - Drawing

    private func render() {
        let finished = progress.isFinished
        switch progress.state {
        case .succeeded: title = doneTitle
        case .cancelled: title = String(localized: "Cancelled")
        case .failed: title = String(localized: "Failed")
        case .interrupted: title = String(localized: "Interrupted")
        default: title = runningTitle
        }
        // the items are made once and swapped only when the task ends: a
        // menu whose item is replaced under it closes, or never opens
        if navigationItem.rightBarButtonItems == nil || barShowsFinished != finished {
            barShowsFinished = finished
            let running = isSheetRoot ? backgroundBarItem : spinnerBarItem
            navigationItem.rightBarButtonItems = finished ? [doneBarItem, menuBarItem] : [running, menuBarItem]
        }

        let stages = progress.shownStages
        let structureChanged = stageCells.map(\.stage) != stages
        let existing = Dictionary(uniqueKeysWithValues: stageCells.map { ($0.stage, $0) })
        stageCells = stages.map { existing[$0] ?? StageCell(stage: $0) }
        for cell in stageCells {
            cell.show(
                progress.state(of: cell.stage),
                subtitle: subtitle(of: cell.stage),
                animated: !structureChanged && !UIAccessibility.isReduceMotionEnabled,
            )
        }
        var sections: [(Section, [Row])] = [(.stages, stages.map(Row.stage))]
        if finished, progress.state != .succeeded {
            sections.append((.outcome, [.outcome(title, progress.message, progress.state)]))
        }
        if !progress.warnings.isEmpty {
            var occurrences: [String: Int] = [:]
            let rows = progress.warnings.map { warning in
                let occurrence = occurrences[warning, default: 0]
                occurrences[warning] = occurrence + 1
                return Row.warning(warning, occurrence: occurrence)
            }
            sections.append((.warnings, rows))
        }
        dataSource.update(sections)
    }

    /// What a stage is doing, or how it ended.
    private func subtitle(of stage: String) -> String {
        switch progress.state(of: stage) {
        case .pending:
            return String(localized: "Waiting")
        case .skipped:
            return String(localized: "Skipped")
        case .done:
            return String(localized: "Done")
        case .failed:
            return progress.state == .cancelled ? String(localized: "Stopped") : String(localized: "Failed")
        case .running:
            var parts: [String] = []
            if progress.countsBytes, progress.completed > 0 {
                let done = ByteCountFormatter.string(fromByteCount: progress.completed, countStyle: .file)
                if let total = progress.total {
                    let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    parts.append(String(localized: "\(done) of \(all)"))
                } else {
                    parts.append(done)
                }
            } else if progress.completed > 0 {
                parts.append(progress.completed.formatted())
            }
            if let speed = progress.bytesPerSecond, speed > 0 {
                let amount = ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file)
                parts.append(String(localized: "\(amount)/s"))
            }
            if parts.isEmpty, let detail = progress.detail, !detail.isEmpty {
                parts.append(detail)
            }
            if parts.isEmpty, let phase = progress.phase {
                return EnvironmentTaskProgress.activeTitle(of: phase)
            }
            return parts.isEmpty ? String(localized: "In Progress…") : parts.joined(separator: " · ")
        }
    }

    /// Whether the bar holds the finished task's items.
    private var barShowsFinished = false
    private lazy var spinnerBarItem = spinnerItem()
    private lazy var doneBarItem = doneItem()
    /// Closes the sheet; the task is the host's and goes on.
    private lazy var backgroundBarItem = UIBarButtonItem(
        title: String(localized: "Continue in Background"),
        primaryAction: UIAction { [weak self] _ in self?.leave() },
    )

    private var isSheetRoot: Bool {
        navigationController?.viewControllers.first === self
    }

    private lazy var menuBarItem = menuItem()

    private func spinnerItem() -> UIBarButtonItem {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = String(localized: "In Progress")
        spinner.startAnimating()
        return UIBarButtonItem(customView: spinner)
    }

    private func doneItem() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "checkmark"),
            primaryAction: UIAction { [weak self] _ in self?.leave() },
        ).then {
            $0.style = .done
            $0.accessibilityLabel = String(localized: "Done")
        }
    }

    private func menuItem() -> UIBarButtonItem {
        UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            }]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
    }

    private func menuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIAction(
                title: String(localized: "View Full Log"),
                image: UIImage(systemName: "text.alignleft"),
            ) { [weak self] _ in
                self?.openLog()
            },
        ]
        if !progress.isFinished {
            elements.append(UIMenu(options: .displayInline, children: [UIAction(
                title: String(localized: "Stop"),
                image: UIImage(systemName: "stop.circle"),
                attributes: cancelRequested ? [.destructive, .disabled] : .destructive,
            ) { [weak self] _ in self?.confirmStop() }]))
        }
        return elements
    }

    // MARK: - Table

    private func cell(for row: Row) -> UITableViewCell? {
        switch row {
        case let .stage(stage):
            return stageCells.first { $0.stage == stage }
        case let .outcome(title, message, state):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.subtitleCell()
            content.text = title
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            content.secondaryText = message
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
            content.secondaryTextProperties.color = .secondaryLabel
            content.textToSecondaryTextVerticalPadding = 4
            content.image = UIImage(
                systemName: state == .cancelled ? "stop.circle.fill" : "exclamationmark.triangle.fill",
            )
            content.imageProperties.tintColor = state == .cancelled ? .secondaryLabel : .systemRed
            cell.contentConfiguration = content
            return cell
        case let .warning(text, _):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemOrange
            cell.contentConfiguration = content
            return cell
        }
    }

    /// Done: back to the page beneath, or — the root of a sheet of its own,
    /// as an import opened from another app is — the sheet closes.
    private func leave() {
        guard let navigation = navigationController else { return }
        if navigation.viewControllers.first === self {
            navigation.dismiss(animated: true)
        } else {
            navigation.popViewController(animated: true)
        }
    }

    // MARK: - Stopping

    private func confirmStop() {
        presentConfirmation(
            title: "Stop This Task?",
            message: "Progress so far is discarded. Starting again begins from scratch.",
            confirmTitle: "Stop",
            destructive: true,
        ) { [weak self] in
            self?.stop()
        }
    }

    private func stop() {
        cancelRequested = true
        Task { [weak self, handle] in
            do {
                try await ApelinService.app.environmentCancel(taskID: handle.taskID)
            } catch {
                guard let self else { return }
                cancelRequested = false
                presentNotice(title: "Unable to Stop", message: error.readableMessage)
            }
        }
    }
}

/// A stage's row, on one line: its name, what it is doing at the end of
/// the line, and Irisin's ring at the trailing edge.
private final class StageCell: UITableViewCell {
    let stage: String
    private let ring = ProgressRing()

    init(stage: String) {
        self.stage = stage
        super.init(style: .default, reuseIdentifier: nil)
        ring.frame = CGRect(origin: .zero, size: ring.intrinsicContentSize)
        accessoryView = ring
        selectionStyle = .none
        // one stop a row: the name, then what it is doing as the value
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(stage:)")
    }

    func show(_ state: EnvironmentTaskProgress.StageState, subtitle: String, animated: Bool) {
        var content = UIListContentConfiguration.valueCell()
        if case .running = state {
            content.text = EnvironmentTaskProgress.activeTitle(of: stage)
        } else {
            content.text = EnvironmentTaskProgress.title(of: stage)
        }
        content.textProperties.color = state == .pending || state == .skipped ? .secondaryLabel : .label
        content.secondaryText = subtitle
        content.secondaryTextProperties.font = .monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular,
        )
        content.secondaryTextProperties.color = state == .failed ? .systemRed : .secondaryLabel
        // one line whatever it says: a row never changes height under the eye,
        // and the name and its state stay side by side
        content.prefersSideBySideTextAndSecondaryText = true
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.numberOfLines = 1
        content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
        contentConfiguration = content

        let appearance: ProgressRing.Appearance
        switch state {
        case .pending:
            appearance = .waiting
        case .skipped:
            appearance = .skipped
        case let .running(fraction):
            ring.tintColor = .tintColor
            appearance = fraction.map { .progress($0) } ?? .working(0)
        case .done:
            ring.tintColor = .systemGreen
            appearance = .glyph("checkmark.circle.fill")
        case .failed:
            ring.tintColor = .systemRed
            appearance = .glyph("info.circle.fill")
        }
        ring.set(appearance, animated: animated)
        accessibilityLabel = content.text
        accessibilityValue = subtitle
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
