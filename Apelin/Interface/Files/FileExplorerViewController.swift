import ApelinCore
import UIKit

final class FileExplorerViewController: UIViewController {
    private let projectName: String
    private var relativePath: String
    private var entries: [(name: String, isDirectory: Bool, size: Int64)] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    /// The files the search field's words answer with; the rows while
    /// `searchQuery` is not empty.
    private var hits: [ProjectFileSearch.Hit] = []
    /// What the search field holds, trimmed: empty when it is not searching.
    ///
    /// A search covers the whole project and not the folder on screen — a
    /// reader looking for a file does not know which folder it is in — so a
    /// hit is a path from the project root, which is what opens it.
    private var searchQuery = ""
    /// The walk the last search started.
    private var scan: Task<Void, Never>?

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.searchResultsUpdater = self
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchBar.placeholder = String(localized: "Search files")
        return controller
    }()

    init(projectName: String, relativePath: String = "") {
        self.projectName = projectName
        self.relativePath = relativePath
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = relativePath.isEmpty ? String(localized: "Files") : (relativePath as NSString).lastPathComponent
        navigationItem.backButtonDisplayMode = .minimal
        // The search bar is not tucked away by a scroll: it is the only way to
        // the words, and the list under it is short.
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        view.backgroundColor = .systemBackground

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "entry")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        loadEntries()
    }

    private func projectRoot() -> String? {
        guard let folder = DataFolder.app.project(named: projectName),
              let path = CanonicalPath.resolve(folder.path)
        else { return nil }
        return path
    }

    private func loadEntries() {
        guard let root = projectRoot() else {
            entries = []
            tableView.reloadData()
            return
        }
        let full = relativePath.isEmpty ? root : root + "/" + relativePath
        guard let resolved = CanonicalPath.resolve(full) else {
            entries = []
            tableView.reloadData()
            return
        }
        let fm = FileManager.default
        var result: [(name: String, isDirectory: Bool, size: Int64)] = []
        if let items = try? fm.contentsOfDirectory(atPath: resolved) {
            for name in items {
                if name.hasPrefix(".") { continue }
                let itemPath = resolved + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: itemPath, isDirectory: &isDir) {
                    var size: Int64 = 0
                    if !isDir.boolValue, let attrs = try? fm.attributesOfItem(atPath: itemPath) {
                        size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    }
                    result.append((name: name, isDirectory: isDir.boolValue, size: size))
                }
            }
        }
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        entries = result
        tableView.reloadData()
    }

    /// Searches the project for `text`, by name and by what its files hold
    /// (`ProjectFileSearch`). The walk is off the main thread and waits for the
    /// reader to stop typing, so a project is not walked per keystroke.
    private func search(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchQuery = query
        scan?.cancel()
        hits = []
        tableView.reloadData()
        guard !query.isEmpty, let root = projectRoot() else { return }
        scan = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) { () -> [ProjectFileSearch.Hit] in
                ProjectFileSearch.search(query, in: URL(fileURLWithPath: root))
            }.value
            guard let self, !Task.isCancelled, self.searchQuery == query else { return }
            self.hits = found
            self.tableView.reloadData()
        }
    }
}

extension FileExplorerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        search(for: searchController.searchBar.text ?? "")
    }
}

extension FileExplorerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        searchQuery.isEmpty ? entries.count : hits.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if !searchQuery.isEmpty {
            let hit = hits[indexPath.row]
            content.text = hit.name
            // Why it is here: the line the words sit in, or the folder it sits
            // in when it answers with its name.
            content.secondaryText = hit.line ?? hit.directory
            content.secondaryTextProperties.numberOfLines = hit.line == nil ? 1 : 2
            content.image = UIImage(systemName: hit.inContent ? "doc.text.magnifyingglass" : "doc.text")
            cell.contentConfiguration = content
            cell.accessoryType = .none
            return cell
        }
        let entry = entries[indexPath.row]
        content.text = entry.name
        if entry.isDirectory {
            content.secondaryText = String(localized: "Folder")
            content.image = UIImage(systemName: "folder")
        } else {
            content.secondaryText = formatSize(entry.size)
            content.image = UIImage(systemName: "doc.text")
        }
        cell.contentConfiguration = content
        cell.accessoryType = entry.isDirectory ? .disclosureIndicator : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !searchQuery.isEmpty {
            // Every answer is a file, in whatever folder of the project it
            // sits: its path is from the project root, which opens it.
            navigationController?.pushViewController(
                FileViewerViewController(projectName: projectName, relativePath: hits[indexPath.row].path),
                animated: true,
            )
            return
        }
        let entry = entries[indexPath.row]
        let childPath = relativePath.isEmpty ? entry.name : relativePath + "/" + entry.name
        if entry.isDirectory {
            navigationController?.pushViewController(
                FileExplorerViewController(projectName: projectName, relativePath: childPath),
                animated: true,
            )
        } else {
            navigationController?.pushViewController(
                FileViewerViewController(projectName: projectName, relativePath: childPath),
                animated: true,
            )
        }
    }

    private func formatSize(_ size: Int64) -> String {
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return String(format: "%.1f KB", Double(size) / 1024.0) }
        return String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
    }
}
