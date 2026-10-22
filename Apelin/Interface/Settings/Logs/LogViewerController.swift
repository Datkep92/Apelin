import Dog
import SnapKit
import UIKit

/// One launch's journal read back as rows: Irisin's log page, given a file
/// (`JournalFile`) in place of Dog's current one.
///
/// The file is parsed once into `parsed` and filtered from there, so a filter
/// change costs a filter rather than a re-parse. The running launch's file is
/// followed while the screen is up: the poll compares the file's size, and
/// only a file that actually grew is read again. An earlier launch's file no
/// longer changes and is read once.
final class LogViewerController: UIViewController, UITableViewDelegate {
    let tableView = FirstFillTableView(frame: .zero, style: .plain)
    let file: JournalFile
    /// The running launch's: followed, and Clear hides what it holds so far.
    let isCurrent: Bool
    let pacing = ListPacing()

    /// Every line in the file, filters not yet applied.
    var parsed: [LogLine] = []
    /// What the table is showing.
    var shown: [LogLine] = []

    var selectedLevels: Set<Dog.DogLevel> = [.verbose, .info, .warning, .error, .critical]
    var selectedCategories: Set<String> = []
    var allCategories: Set<String> {
        Set(parsed.map(\.category))
    }

    /// Characters Clear hid from the top of the file.
    var hiddenPrefixCount = 0

    /// Size of the file at the last parse, so the poll can skip a file that
    /// has not moved.
    var lastReadLength = -1
    private var tail: Timer?
    /// The first parse, off the main actor from init; nil once the rows are
    /// in `parsed`.
    var work: Task<Void, Never>?

    init(file: JournalFile, isCurrent: Bool) {
        self.file = file
        self.isCurrent = isCurrent
        super.init(nibName: nil, bundle: nil)
        lastReadLength = fileLength
        let url = file.url
        work = Task { [weak self] in
            let lines = await Task.detached {
                LogViewerController.parseLogLines(LogViewerController.text(of: url, hiding: 0))
            }.value
            guard let self, !Task.isCancelled else { return }
            work = nil
            parsed = lines
            if isViewLoaded {
                applyFilters(stickToBottom: true)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(file:isCurrent:)")
    }

    /// A line's place in the log is its identity: the same text can be
    /// written twice and both rows have to exist.
    struct Row: Hashable, Sendable {
        let index: Int
        let line: LogLine
    }

    lazy var dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { tableView, _, row in
        let id = "LogCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        Self.configure(cell, with: row.line)
        return cell
    }

    /// Unchecked only because `Dog.DogLevel` predates Sendable; it is an
    /// enum over string raw values and every other field is a `String`.
    struct LogLine: Hashable, @unchecked Sendable {
        let timestamp: String
        let level: Dog.DogLevel
        let category: String
        let message: String
        let fullText: String

        func appending(_ line: String) -> LogLine {
            LogLine(
                timestamp: timestamp,
                level: level,
                category: category,
                message: message + "\n" + line,
                fullText: fullText + "\n" + line,
            )
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = LogsController.title(of: file)
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never

        setupNavigationItems()
        setupTableView()
        // rows already parsed go up with the view; otherwise the first
        // parse applies them when it lands
        if work == nil {
            applyFilters(stickToBottom: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard isCurrent else { return }
        // The running launch writes while it is being read. A sheet
        // dismissed over this screen appears it again without ever
        // disappearing it: the previous timer goes first.
        tail?.invalidate()
        tail = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfFileGrew() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tail?.invalidate()
        tail = nil
    }

    private func setupTableView() {
        tableView.dataSource = dataSource
        tableView.delegate = self
        tableView.estimatedRowHeight = 60
        tableView.rowHeight = UITableView.automaticDimension
        tableView.separatorStyle = .singleLine
        tableView.backgroundColor = .pageBackground
        tableView.keyboardDismissMode = .onDrag
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    /// `growing` for new lines from the file, which may animate in a list
    /// that sat still (`ListPacing`); a filter or Clear shows other rows and
    /// never does.
    func applyFilters(stickToBottom: Bool, growing: Bool = false) {
        shown = parsed.filter { line in
            selectedLevels.contains(line.level)
                && (selectedCategories.isEmpty || selectedCategories.contains(line.category))
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(shown.enumerated().map { Row(index: $0.offset, line: $0.element) })
        guard tableView.isFilled else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView) { [weak self] in
                if stickToBottom {
                    self?.scrollToBottom(animated: false)
                }
            }
            return
        }
        if !growing {
            pacing.begin()
        }
        let animated = pacing.animatesChange(in: tableView)
        dataSource.applyChange(snapshot, to: tableView, animated: animated) { [weak self] in
            if stickToBottom {
                self?.scrollToBottom(animated: animated)
            }
        }
    }

    /// Following the file must not fight someone reading further up, so new
    /// lines only pull the view down when it was already at the end.
    var isNearBottom: Bool {
        guard tableView.contentSize.height > tableView.bounds.height else { return true }
        let distance = tableView.contentSize.height
            - tableView.contentOffset.y
            - tableView.bounds.height
            + tableView.adjustedContentInset.bottom
        return distance < 60
    }

    private func scrollToBottom(animated: Bool) {
        guard !shown.isEmpty, !tableView.isTracking, !tableView.isDecelerating else { return }
        tableView.scrollToRow(at: IndexPath(row: shown.count - 1, section: 0), at: .bottom, animated: animated)
    }

    private static func configure(_ cell: UITableViewCell, with logLine: LogLine) {
        var content = UIListContentConfiguration.subtitleCell()
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular,
        )
        content.text = logLine.message
        content.textProperties.font = font
        content.textProperties.numberOfLines = 0
        content.secondaryText = logLine.timestamp.isEmpty
            ? logLine.category
            : "\(logLine.timestamp) • \(logLine.category)"
        content.secondaryTextProperties.font = font
        content.secondaryTextProperties.numberOfLines = 1

        switch logLine.level {
        case .verbose:
            content.textProperties.color = .logVerbose
            content.secondaryTextProperties.color = .logVerboseDetail
            cell.backgroundColor = .pageBackground
        case .info:
            content.textProperties.color = .label
            content.secondaryTextProperties.color = .secondaryLabel
            cell.backgroundColor = .pageBackground
        case .warning:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .pageBackground
        case .error:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .logErrorBackground
        case .critical:
            content.textProperties.color = .logProblem
            content.secondaryTextProperties.color = .logProblemDetail
            cell.backgroundColor = .logCriticalBackground
        }

        cell.contentConfiguration = content
        cell.selectionStyle = .none
        // the level is drawn only in colour: spoken first in the value,
        // before when and where the line was written
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = logLine.message
        cell.accessibilityValue = [name(of: logLine.level), content.secondaryText ?? ""].joined(separator: ", ")
    }
}
