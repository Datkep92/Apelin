import ApelinCore
import Foundation
import Then
import UIKit
import UniformTypeIdentifiers

/// Settings groups agent preferences, the development environment, Git and About.
/// Only Memories shows a count, refreshed whenever Settings appears.
/// The `…` in the bar opens onboarding again or a new GitHub issue.
final class SettingsViewController: TableController {
    private enum Section: Hashable, CaseIterable {
        case agent
        case environment
        case git
        case services
        case about
    }

    private enum Row: Hashable {
        case modelProviders
        case permissionMode
        case memories
        case skills
        case commands
        case configuration
        case toolchain
        case sdks
        case templates
        case git
        case services
        case version
        case licenses
        case logs
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String?
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    private func updateRows() {
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map { row in
                let detail: String? = switch row {
                case .permissionMode: AgentPermissions.title(for: AgentPermissions.mode)
                case .memories: memorySummary
                default: nil
                }
                return RowContent(row: row, detail: detail)
            })
        }, reconfigure: true)
    }

    private var memorySummary: String?
    private var loader: Task<Void, Never>?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Open Onboarding"),
                    image: UIImage(systemName: "hand.wave"),
                ) { [weak self] _ in self?.openOnboarding() },
                UIAction(
                    title: String(localized: "Report a Problem"),
                    image: UIImage(systemName: "exclamationmark.bubble"),
                ) { _ in Self.reportProblem() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        dataSource.beginLoad()
        updateRows()
        loadMemorySummary()
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .agent: [.modelProviders, .permissionMode, .memories, .skills, .commands, .configuration]
        case .environment: [.toolchain, .sdks, .templates]
        case .git: [.git]
        case .services: [.services]
        case .about: [.version, .licenses, .logs]
        }
    }

    private func loadMemorySummary() {
        loader?.cancel()
        let store = MemoryStore(root: DataFolder.app.root)
        loader = Task { [weak self] in
            let count = await Task.detached { try? store.read().records.count }.value
            guard !Task.isCancelled, let self else { return }
            memorySummary = count?.formatted()
            updateRows()
        }
    }

    private func header(for section: Section) -> String? {
        switch section {
        case .agent: String(localized: "Agent")
        case .environment: String(localized: "Environment")
        case .git: nil
        case .services: nil
        case .about: String(localized: "About")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .agent: nil
        case .environment: nil
        case .git:
            String(localized: "The author of your commits, your GitHub account, and the package repository your releases are published to.")
        case .services:
            String(localized: "Per-project configuration for GitHub, Firebase, Cloudflare, Google Script and Telegram.")
        case .about: nil
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "setting")
        var content = UIListContentConfiguration.valueCell()
        content.secondaryText = value.detail
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch value.row {
        case .modelProviders:
            content.text = String(localized: "Model Providers")
        case .permissionMode:
            content.text = String(localized: "Permission Mode")
        case .memories:
            content.text = String(localized: "Memories")
        case .skills:
            content.text = String(localized: "Skills")
        case .commands:
            content.text = String(localized: "Commands")
        case .configuration:
            content.text = String(localized: "Configuration")
            content.secondaryText = String(localized: "Export or import a portable configuration bundle")
        case .toolchain:
            content.text = String(localized: "Toolchains")
        case .sdks:
            content.text = String(localized: "SDKs")
        case .templates:
            content.text = String(localized: "Templates")
        case .git:
            content.text = String(localized: "Git")
        case .services:
            content.text = String(localized: "Services")
        case .version:
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "?"
            let build = info?["CFBundleVersion"] as? String ?? "?"
            content.text = String(localized: "Version")
            content.secondaryText = "\(version) (\(build))"
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case .licenses:
            content.text = String(localized: "Open Source Licenses")
        case .logs:
            content.text = String(localized: "Logs")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .version = dataSource.value(at: indexPath)?.row {
            return false
        }
        return true
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        let page: UIViewController
        switch row {
        case .modelProviders: page = ModelProvidersController()
        case .permissionMode: page = PermissionModeController()
        case .memories: page = MemoriesController()
        case .skills: page = SkillsController()
        case .commands: page = CommandsController()
        case .configuration: page = ConfigurationController()
        case .toolchain: page = ToolchainController()
        case .sdks: page = SDKListController()
        case .templates: page = TemplatesController()
        case .git: page = GitSettingsController()
        case .services:
            // Services config is per-project, so the projects come first: in
            // this sheet's own stack, not in a sheet over it, which would
            // have covered the settings it goes on to open.
            Task { [weak self] in
                let projects = (try? await ProjectSummary.load()) ?? []
                guard let self, let navigation = self.navigationController else { return }
                let picker = ProjectPickerController(projects: projects, current: nil)
                picker.onPick = { [weak navigation] project in
                    guard let navigation else { return }
                    var stack = navigation.viewControllers.filter { !($0 is ProjectPickerController) }
                    stack.append(ServicesSettingsController(projectName: project.name))
                    navigation.setViewControllers(stack, animated: true)
                }
                navigation.pushViewController(picker, animated: true)
            }
            return
        case .licenses: page = LicensesViewController()
        case .logs: page = LogsController()
        case .version: return
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// Settings as the sidebar's gear opens it, but already at Git, for a
    /// page whose next step is set up there: a package repository, and the
    /// GitHub sign-in it needs. Back leads to the rest of Settings.
    static func presentGit(from presenter: UIViewController) {
        let settings = SettingsViewController()
        // the Git page's Back is made from the title and back button mode
        // this page sets as it loads
        settings.loadViewIfNeeded()
        presenter.presentPageAsFormSheet(settings, openedAt: GitSettingsController())
    }

    /// Closes Settings and shows the welcome pages from the start.
    private func openOnboarding() {
        guard let root = view.window?.rootViewController as? RootInterfaceController else { return }
        navigationController?.dismiss(animated: true) { [weak root] in root?.presentWelcome() }
    }

    /// A new issue on Apelin's repository, in the browser.
    private static func reportProblem() {
        guard let url = URL(string: "https://github.com/owngoal-dev/Apelin/issues/new") else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Configuration export/import

final class ConfigurationController: UIViewController, UIDocumentPickerDelegate {
    private let statusLabel = UILabel()
    private let exportButton = UIButton()
    private let importButton = UIButton()
    private let scopeLabel = UILabel()
    private let root: URL = DataFolder.app.root

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Configuration")
        view.backgroundColor = .systemBackground
        buildUI()
    }

    private func buildUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = String(localized: "Export remembers Memories, Skills, Commands, Git, distribution and provider metadata, and project display names. Project code, toolchains, SDKs, builds, journals, sessions, caches and install metadata are excluded.")

        scopeLabel.font = .preferredFont(forTextStyle: .footnote)
        scopeLabel.textColor = .secondaryLabel
        scopeLabel.numberOfLines = 0
        scopeLabel.text = String(localized: "Secrets are not included. Optional passphrase protection is not yet implemented.")

        exportButton.configuration = .filled()
        exportButton.setTitle(String(localized: "Export Configuration…"), for: .normal)
        exportButton.accessibilityLabel = String(localized: "Export Configuration")
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)

        importButton.configuration = .tinted()
        importButton.setTitle(String(localized: "Import Configuration…"), for: .normal)
        importButton.accessibilityLabel = String(localized: "Import Configuration")
        importButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(exportButton)
        stack.addArrangedSubview(importButton)
        stack.addArrangedSubview(scopeLabel)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    @objc private func exportTapped() {
        Task { await export() }
    }

    private func export() async {
        setActionsEnabled(false)
        defer { setActionsEnabled(true) }
        do {
            let inf = Bundle.main.infoDictionary
            let appVersion = (inf?["CFBundleShortVersionString"] as? String) ?? "unknown"
            let buildNumber = (inf?["CFBundleVersion"] as? String) ?? "unknown"
            let root = self.root
            let bundle = try await Task.detached(priority: .userInitiated) {
                let (files, scopes) = ConfigBundleCollector.collect(from: root)
                return try ConfigBundleBuilder.build(
                    files: files,
                    scopes: scopes,
                    appVersion: appVersion,
                    buildNumber: buildNumber,
                )
            }.value

            let data = try bundle.data()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Apelin-Configuration-\(Self.dateStamp()).apelinbak", isDirectory: false)
            try data.write(to: url, options: .atomic)
            await MainActor.run {
                let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: url)
                }
                if let popover = sheet.popoverPresentationController {
                    popover.sourceView = self.view
                    popover.sourceRect = self.view.bounds
                }
                self.present(sheet, animated: true)
            }
        } catch {
            await MainActor.run {
                self.presentNotice(title: "Unable to Export", message: String(describing: error))
            }
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }

    @objc private func importTapped() {
        let type = UTType(filenameExtension: "apelinbak") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [type])
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        Task { await importConfiguration(from: url) }
    }

    private func importConfiguration(from url: URL) async {
        setActionsEnabled(false)
        defer { setActionsEnabled(true) }
        do {
            let data: Data = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                return try Data(contentsOf: url)
            }.value

            let envelope = try ConfigBundleParser.load(data)
            try ConfigBundleParser.verify(envelope)

            let root = self.root
            let backup = root.appendingPathComponent(".config-import-backup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)

            var backedRelative: [String] = []
            for file in envelope.manifest.files {
                let target = root.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: target.path) {
                    let backupURL = backup.appendingPathComponent(file.path)
                    try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: target, to: backupURL)
                    backedRelative.append(file.path)
                }
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    try ConfigBundleParser.extract(bundle: envelope, into: root, overwrite: true)
                }.value
            } catch {
                for relative in backedRelative {
                    let backupURL = backup.appendingPathComponent(relative)
                    let target = root.appendingPathComponent(relative)
                    try? FileManager.default.removeItem(at: target)
                    if FileManager.default.fileExists(atPath: backupURL.path) {
                        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? FileManager.default.copyItem(at: backupURL, to: target)
                    }
                }
                throw error
            }

            let titlesURL = root.appendingPathComponent("Settings/projectTitles.json")
            if FileManager.default.fileExists(atPath: titlesURL.path),
               let titlesData = try? Data(contentsOf: titlesURL),
               let object = try? JSONSerialization.jsonObject(with: titlesData) as? [String: Any],
               let entries = object["projectTitles"] as? [[String: String]] {
                let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
                for entry in entries {
                    guard let name = entry["name"], let displayName = entry["displayName"], !name.isEmpty, !displayName.isEmpty else { continue }
                    let projectFile = projectsRoot.appendingPathComponent(name).appendingPathComponent("apelin-project.json")
                    guard FileManager.default.fileExists(atPath: projectFile.path),
                          let projectData = try? Data(contentsOf: projectFile),
                          let projectObject = try? JSONSerialization.jsonObject(with: projectData) as? [String: Any] else { continue }
                    var updated = projectObject
                    updated["displayName"] = displayName
                    if let updatedData = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted]) {
                        try? updatedData.write(to: projectFile, options: .atomic)
                    }
                }
            }

            try? FileManager.default.removeItem(at: titlesURL)
            try? FileManager.default.removeItem(at: backup)

            await MainActor.run {
                NotificationCenter.default.post(name: TransferOpener.environmentChanged, object: nil)
                self.presentNotice(title: "Imported", message: "Configuration applied. Restart Apelin to fully reload agent data if needed.")
            }
        } catch {
            await MainActor.run {
                self.presentNotice(title: "Unable to Import", message: String(describing: error))
            }
        }
    }

    private func setActionsEnabled(_ enabled: Bool) {
        exportButton.isEnabled = enabled
        importButton.isEnabled = enabled
    }
}

private enum ConfigBundleCollector {
    static func collect(from root: URL) -> ([String: Data], [String]) {
        let fm = FileManager.default
        let rootPath = CanonicalPath.resolve(root.path) ?? root.path
        var files: [String: Data] = [:]
        var scopes = Set<String>()

        func addFile(_ relative: String) {
            let target = root.appendingPathComponent(relative)
            guard let canonicalPath = CanonicalPath.resolve(target.path),
                  CanonicalPath.isCanonical(canonicalPath, inside: rootPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath)),
                  data.count <= ConfigBundleSchema.maximumFileBytes else { return }
            files[relative] = data
        }

        func walk(_ base: String) {
            let baseURL = root.appendingPathComponent(base, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else { return }
            guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    continue
                }
                guard let resolved = CanonicalPath.resolve(url.path),
                      CanonicalPath.isCanonical(resolved, inside: rootPath) else { continue }
                let relative = String(resolved.dropFirst(rootPath.count + 1))
                guard !relative.isEmpty, !relative.hasPrefix("../"), !relative.hasPrefix("/") else { continue }
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)),
                      data.count <= ConfigBundleSchema.maximumFileBytes else { continue }
                files[relative] = data
            }
        }

        addFile("memories.json")

        walk("commands")
        if files.keys.contains(where: { $0 == "commands" || $0.hasPrefix("commands/") }) { scopes.insert("commands") }

        let skillsBefore = files.count
        walk("skills")
        if files.count > skillsBefore { scopes.insert("skills") }

        let settingsSupported = [
            "Settings/git.json",
            "Settings/distribution.json",
            "Settings/Providers/ApelinCustomProviders.plist",
        ]
        var settingsAdded = false
        var providerAdded = false
        for relative in settingsSupported {
            let before = files.count
            addFile(relative)
            if files.count > before {
                settingsAdded = true
                if relative.contains("Providers") { providerAdded = true }
            }
        }
        if settingsAdded { scopes.insert("settings") }
        if providerAdded { scopes.insert("provider-metadata") }
        if files.keys.contains(where: { $0 == "memories.json" }) { scopes.insert("memories") }

        let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(atPath: projectsRoot.path) {
            var entries: [[String: String]] = []
            for name in children {
                let projectFile = projectsRoot.appendingPathComponent(name).appendingPathComponent("apelin-project.json")
                guard let data = try? Data(contentsOf: projectFile),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let displayName = object["displayName"] as? String,
                      !displayName.isEmpty else { continue }
                entries.append(["name": name, "displayName": displayName])
            }
            if !entries.isEmpty,
               let titlesData = try? JSONSerialization.data(withJSONObject: ["projectTitles": entries], options: [.prettyPrinted, .sortedKeys]) {
                files["Settings/projectTitles.json"] = titlesData
                scopes.insert("project-titles")
            }
        }

        return (files, scopes.sorted())
    }
}
