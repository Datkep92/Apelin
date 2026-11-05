import SnapKit
import Then
import UIKit

/// Every line a task said, in order: the page behind a task's menu, for
/// whoever wants the whole account. Irisin's operation log: a number and a
/// monospaced line each, following the end while the task runs and reading
/// the same once it is over. The share button hands the text on.
final class TaskLogController: UIViewController {
    private let tableView = FirstFillTableView(frame: .zero, style: .plain)
    private var lines: [String]
    /// A refresh asked for while one is waiting is folded into it: lines
    /// arrive in bursts while a download counts.
    private var refreshPending = false
    private var displayedLines: [String] = []
    private let pacing = ListPacing()

    private lazy var dataSource = UITableViewDiffableDataSource<Int, Int>(
        tableView: tableView,
    ) { [weak self] table, indexPath, line in
        let cell = table.dequeueReusableCell(withIdentifier: TaskLogCell.reuseIdentifier, for: indexPath)
        (cell as? TaskLogCell)?.configure(
            number: line + 1,
            message: self.flatMap { $0.lines.indices.contains(line) ? $0.lines[line] : nil } ?? "",
        )
        return cell
    }

    init(lines: [String]) {
        self.lines = lines
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(lines:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Full Log")
        view.backgroundColor = .pageBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .action,
            primaryAction: UIAction { [weak self] _ in self?.share() },
        ).then { $0.accessibilityLabel = String(localized: "Share Log") }

        tableView.backgroundColor = .pageBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 28
        tableView.separatorStyle = .none
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 20, right: 0)
        tableView.allowsSelection = false
        tableView.register(TaskLogCell.self, forCellReuseIdentifier: TaskLogCell.reuseIdentifier)
        view.addSubview(tableView)
        tableView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
        }
        apply()
    }

    /// The task's lines so far; the table catches up at most ten times a
    /// second and always ends on the latest.
    func update(_ lines: [String]) {
        self.lines = lines
        guard isViewLoaded, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshPending = false
            self?.apply()
        }
    }

    private func share() {
        let share = UIActivityViewController(activityItems: [lines.joined(separator: "\n")], applicationActivities: nil)
        share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(share, animated: true)
    }

    /// Shows the newest log line at the top so the user need not scroll
    /// to see the result of a just-expanded task; earlier lines read below it.
    /// Following still keeps the newest line in view while the task runs.
    private func apply() {
        // With the newest line at the top, the anchor is the first row.
        let anchorVisible = tableView.indexPathsForVisibleRows?.contains(IndexPath(row: 0, section: 0)) == true
        let follow = anchorVisible && !tableView.isTracking && !tableView.isDecelerating
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        // a row is its position: the same line can be said twice. New tasks say
        // the most recent events first while keeping each line's number.
        snapshot.appendItems(Array(lines.indices).reversed())
        let changed = lines.indices.filter { displayedLines.indices.contains($0) && displayedLines[$0] != lines[$0] }
        guard !tableView.isFilled || displayedLines != lines else { return }
        snapshot.reconfigureItems(changed)
        displayedLines = lines
        let animated = tableView.isFilled && pacing.animatesChange(in: tableView)
        // newest line sits at the top of the now-reversed list
        let newestItem = snapshot.itemIdentifiers.first
        let scroll = { [weak self] in
            guard let self, follow, !tableView.isTracking, !tableView.isDecelerating,
                  newestItem != nil else { return }
            if self.dataSource.indexPath(for: newestItem!) != nil {
                self.tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: animated)
            }
        }
        if tableView.isFilled {
            dataSource.applyChange(snapshot, to: tableView, animated: animated, completion: scroll)
        } else {
            pacing.begin()
            dataSource.applyFirst(snapshot, to: tableView, completion: scroll)
        }
    }
}

/// A log line: its number in a narrow column, the text beside it.
private final class TaskLogCell: UITableViewCell {
    static let reuseIdentifier = "log"

    private let numberLabel = UILabel()
    private let messageLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .pageBackground
        selectionStyle = .none
        numberLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular,
        )
        numberLabel.textColor = .secondaryLabel
        numberLabel.textAlignment = .right
        messageLabel.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
            weight: .regular,
        )
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        contentView.addSubview(numberLabel)
        contentView.addSubview(messageLabel)
        numberLabel.snp.makeConstraints { x in
            x.leading.equalToSuperview().inset(12)
            x.width.equalTo(32)
            x.firstBaseline.equalTo(messageLabel)
        }
        messageLabel.snp.makeConstraints { x in
            x.leading.equalTo(numberLabel.snp.trailing).offset(12)
            x.trailing.equalToSuperview().inset(20)
            x.top.bottom.equalToSuperview().inset(5)
        }
        // the line is the row; its number is only drawn
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    func configure(number: Int, message: String) {
        numberLabel.text = String(number)
        messageLabel.text = message
        accessibilityLabel = message
    }

    /// The number stands against the line it numbers: on its right left
    /// to right, on its left right to left.
    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.textAlignment = laysOutRightToLeft ? .left : .right
    }
}
