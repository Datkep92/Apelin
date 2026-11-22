import UIKit

/// The words a reader types on the chat page, looked for inside every
/// conversation the runtime knows — in every project, not only the one open.
/// The sidebar's search finds conversation names; this one finds what was
/// said, and names where it was said.
final class ChatContentSearchController: UITableViewController {
    private struct Result {
        let summary: ChatSummary
        let line: String
    }

    private let runtime: ChatRuntime
    /// The conversation picked, for the root to put on the page and, when it
    /// belongs to another project, to switch to that project first.
    var onPick: ((ChatSummary) -> Void)?
    private var query = ""
    private var results: [Result] = []
    private var scan: Task<Void, Never>?

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = String(localized: "Search chats")
        return controller
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "No Results")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(runtime:)") }

    deinit { scan?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Search chats")
        navigationItem.backButtonDisplayMode = .minimal
        // The field is the only way to the findings, so a scroll must not
        // tuck it away (`FileExplorerViewController` does the same).
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "hit")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchController.searchBar.becomeFirstResponder()
    }

    /// Reads one conversation at a time, so a finding joins the list as soon
    /// as it is known rather than after every project's history is read. As in
    /// the sidebar, the read waits for a pause and starts at two characters.
    private func search(for text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = words
        scan?.cancel()
        results = []
        refresh()
        guard words.count >= 2 else { return }
        let summaries = runtime.summaries.sorted { $0.lastInteraction > $1.lastInteraction }
        scan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            for summary in summaries {
                guard !Task.isCancelled, self.query == words else { return }
                guard let hit = await self.runtime.contentHit(words, in: summary.id) else { continue }
                guard !Task.isCancelled, self.query == words else { return }
                self.results.append(Result(summary: summary, line: hit.line))
                self.refresh()
            }
        }
    }

    private func refresh() {
        tableView.backgroundView = (query.isEmpty || !results.isEmpty) ? nil : emptyLabel
        tableView.reloadData()
    }
}

extension ChatContentSearchController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        search(for: searchController.searchBar.text ?? "")
    }
}

extension ChatContentSearchController {
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        results.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "hit", for: indexPath)
        let result = results[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = result.summary.displayTitle
        content.textProperties.numberOfLines = 1
        content.secondaryText = [result.summary.projectName, result.line]
            .compactMap { $0 }.joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        // The cell labels itself: the subviews must not be read one by one.
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = [result.summary.displayTitle, result.summary.projectName]
            .compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityValue = result.line
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let summary = results[indexPath.row].summary
        // Get out of the way first, so opening the conversation does not
        // leave this page between the reader and the chat they picked.
        navigationController?.popViewController(animated: false)
        onPick?(summary)
    }
}
