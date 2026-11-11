import ApelinCore
import UIKit

final class FileExplorerViewController: UIViewController {
    private let projectName: String
    private var relativePath: String
    private var entries: [(name: String, isDirectory: Bool, size: Int64)] = []
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

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
}

extension FileExplorerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "entry", for: indexPath)
        let entry = entries[indexPath.row]
        var content = cell.defaultContentConfiguration()
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
