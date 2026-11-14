import Foundation
import UIKit

/// A chat slash command loaded from `~/Documents/wiki.qaq.apelin/commands/`.
struct ChatCommand {
    let name: String
    let description: String
    let template: String

    /// Expands the template with the user's content.
    func expand(content: String) -> String {
        template.replacingOccurrences(of: "{{content}}", with: content)
    }
}

/// Loads, lists and expands slash commands stored globally.
final class ChatCommandStore {
    static let shared = ChatCommandStore()

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("wiki.qaq.apelin", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
        }
    }

    /// Ensures the commands directory exists and ships default commands if empty.
    func ensureDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasCommands = existing.contains { $0.hasSuffix(".md") }
        guard !hasCommands else { return }
        for (name, content) in Self.defaultCommands {
            let url = directory.appendingPathComponent("\(name).md")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Public access to the commands directory for management UI.
    var directoryURL: URL { directory }

    /// Parses a command file for display/editing.
    func command(at url: URL) -> ChatCommand? { parse(url) }

    /// All available commands, sorted by name.
    func all() -> [ChatCommand] {
        ensureDefaults()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [ChatCommand] = []
        for file in files where file.pathExtension == "md" {
            if let command = parse(file) { result.append(command) }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Finds a command by name.
    func find(_ name: String) -> ChatCommand? {
        all().first { $0.name == name }
    }

    /// Expands a slash command in text. Returns (expandedText, commandName) if matched.
    func expand(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        // parse: /name rest...
        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let name = String(first).lowercased()
        guard let command = find(name) else { return nil }
        let content = parts.count > 1 ? String(parts[1]) : ""
        return (command.expand(content: content), name)
    }

    // MARK: - Parsing

    private func parse(_ url: URL) -> ChatCommand? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Split frontmatter
        let lines = raw.components(separatedBy: "\n")
        var name: String?
        var description = ""
        var templateStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    templateStart = i + 1
                    break
                }
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = kv[1].trimmingCharacters(in: .whitespaces)
                    if key == "name" { name = val }
                    if key == "description" { description = val }
                }
                i += 1
            }
        } else {
            // No frontmatter: use filename as name
            name = url.deletingPathExtension().lastPathComponent
            templateStart = 0
        }
        guard let cmdName = name, !cmdName.isEmpty else {
            name = url.deletingPathExtension().lastPathComponent
            guard let n = name, !n.isEmpty else { return nil }
            // fallback
            let template = lines.joined(separator: "\n")
            return ChatCommand(name: n, description: description, template: template)
        }
        let template = lines[templateStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatCommand(name: cmdName, description: description, template: template)
    }

    // MARK: - Defaults

    static let defaultCommands: [(String, String)] = [
        ("plan", """
        ---
        name: plan
        description: Lập kế hoạch chi tiết trước khi code
        ---
        Bạn là planner. Hãy lập kế hoạch chi tiết cho task sau, KHÔNG viết code, chỉ phân tích và đề xuất các bước:

        {{content}}
        """)
        ,
        ("build", """
        ---
        name: build
        description: Hướng dẫn build và kiểm tra sản phẩm
        ---
        Hãy thực hiện build và kiểm tra sản phẩm theo task sau, báo cáo lỗi nếu có:

        {{content}}
        """)
        ,
        ("review", """
        ---
        name: review
        description: Review code theo best practices
        ---
        Hãy review code sau theo best practices, chỉ ra vấn đề và đề xuất cải thiện:

        {{content}}
        """)
        ,
        ("explain", """
        ---
        name: explain
        description: Giải thích code hoặc khái niệm
        ---
        Hãy giải thích rõ ràng, dễ hiểu cho người không chuyên về code:

        {{content}}
        """)
        ,
        ("fix", """
        ---
        name: fix
        description: Tìm và sửa lỗi
        ---
        Hãy tìm nguyên nhân gốc rễ và sửa lỗi sau, kiểm tra regression:

        {{content}}
        """)
        ,
    ]
}

// MARK: - Command management UI

final class CommandsController: TableController {
    private var files: [URL] = []
    private let fm = FileManager.default

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Commands")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.create() },
        ).then { $0.accessibilityLabel = String(localized: "Add Command") }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "command")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private var directory: URL { ChatCommandStore.shared.directoryURL }

    private func load() {
        ChatCommandStore.shared.ensureDefaults()
        files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        tableView.reloadData()
    }

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        files.isEmpty ? 1 : files.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "command", for: indexPath)
        if files.isEmpty {
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No commands yet")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }
        let url = files[indexPath.row]
        let command = ChatCommandStore.shared.command(at: url)
        var content = UIListContentConfiguration.stackedValueCell()
        content.text = "/" + (command?.name ?? url.deletingPathExtension().lastPathComponent)
        content.secondaryText = command?.description.isEmpty == false ? command?.description : url.lastPathComponent
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !files.isEmpty else { return }
        openEditor(for: files[indexPath.row])
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard !files.isEmpty else { return nil }
        let url = files[indexPath.row]
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            completion(false)
            self?.confirmDelete(url)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func confirmDelete(_ url: URL) {
        presentConfirmation(
            title: String.LocalizationValue("Delete \(url.deletingPathExtension().lastPathComponent)?"),
            message: "The command file is removed from the commands folder.",
            confirmTitle: "Delete",
            destructive: true,
        ) { [weak self] in
            try? self?.fm.removeItem(at: url)
            self?.load()
        }
    }

    private func create() {
        let alert = UIAlertController(
            title: String(localized: "New Command"),
            message: nil,
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "Name")
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Create"), style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }
            let url = self.directory.appendingPathComponent("\(name).md")
            let template = """
            ---
            name: \(name)
            description:
            ---

            Your prompt here with {{content}}
            """
            try? template.write(to: url, atomically: true, encoding: .utf8)
            self.load()
            self.openEditor(for: url)
        })
        present(alert, animated: true)
    }

    private func openEditor(for url: URL) {
        navigationController?.pushViewController(CommandEditorController(url: url), animated: true)
    }
}

final class CommandEditorController: UIViewController {
    let url: URL
    private let textView = UITextView()

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(url:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = url.lastPathComponent
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Save"),
            style: .done,
            target: self,
            action: #selector(save),
        )
        textView.text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func save() {
        try? textView.text.write(to: url, atomically: true, encoding: .utf8)
        navigationController?.popViewController(animated: true)
    }
}
