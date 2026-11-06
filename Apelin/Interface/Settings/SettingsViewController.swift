// MARK: - Configuration export/import

private extension String {
    static let empty: Self = ""
}

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
        scopeLabel.text = String(localized: "Secrets are not included. You can optionally protect imported configuration with your own passphrase later; this release exports plaintext configuration only.")

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
                self.presentNotice(title: String(localized: "Unable to Export"), message: String(describing: error))
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
                // Roll back copied files.
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

            // Apply project display titles if present.
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

            // Remove transient title file after applying.
            try? FileManager.default.removeItem(at: titlesURL)

            // Cleanup backup.
            try? FileManager.default.removeItem(at: backup)

            // Reload signals for settings/memory/skills/commands.
            await MainActor.run {
                NotificationCenter.default.post(name: TransferOpener.environmentChanged, object: nil)
                self.presentNotice(title: String(localized: "Imported"), message: String(localized: "Configuration applied. Restart Apelin to fully reload agent data if needed."))
            }
        } catch {
            await MainActor.run {
                self.presentNotice(title: String(localized: "Unable to Import"), message: String(describing: error))
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
            let canonicalPath = CanonicalPath.resolve(root.appendingPathComponent(relative).path) ?? root.appendingPathComponent(relative).path
            guard CanonicalPath.isCanonical(canonicalPath, inside: rootPath), let data = try? Data(contentsOf: URL(fileURLWithPath: canonicalPath)), data.count <= ConfigBundleSchema.maximumFileBytes else { return }
            files[relative] = data
        }

        func walk(_ base: String) {
            let baseURL = root.appendingPathComponent(base, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: baseURL.path, isDirectory: &isDir), isDir.boolValue else { return }
            guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isSymbolicLink == true {
                    continue
                }
                var isRegular = false
                if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) {
                    isRegular = values.isRegularFile ?? false
                } else {
                    var isRegularObjC: ObjCBool = false
                    isRegular = fm.fileExists(atPath: url.path, isDirectory: &isRegularObjC) && !isRegularObjC.boolValue
                }
                guard isRegular else { continue }
                guard let resolved = CanonicalPath.resolve(url.path) else { continue }
                guard CanonicalPath.isCanonical(resolved, inside: rootPath) else { continue }
                var relative = String(resolved.dropFirst(rootPath.count + 1))
                if relative.hasPrefix("../") || relative.hasPrefix("/") { continue }
                if relative.isEmpty { continue }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: resolved)), data.count <= ConfigBundleSchema.maximumFileBytes {
                    files[relative] = data
                }
            }
        }

        // Top-level known files
        addFile("memories.json")

        // Sibling folders
        for relative in ["commands"] {
            walk(relative)
            if files.keys.contains(where: { $0 == "commands" || $0.hasPrefix("commands/") }) { scopes.insert("commands") }
        }
        let skillsBefore = files.count
        walk("skills")
        if files.count > skillsBefore { scopes.insert("skills") }

        // Settings, distribution and provider metadata only by exact names
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

        // Project display names only; no project content.
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