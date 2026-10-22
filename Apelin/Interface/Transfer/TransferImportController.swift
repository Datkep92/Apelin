import ApelinCore
import ApelinProtocol
import SnapKit
import Then
import UIKit

/// Open in Apelin ▸ the confirmation: what the file holds, what it needs,
/// what would stop it, and Import. The manifest is read by the session host
/// (`transferInspect`), which says whether an import would start here; the
/// payload is checked by the import itself, before anything is installed or
/// registered. Import hands over to `EnvironmentTaskController` in the same
/// place.
final class TransferImportController: TableController {
    private enum Field: Hashable {
        case version, languages, swiftVersion, newestSDK, appleProduct, name, architectures, swiftInterfaces,
             template, gitHistory, remote, toolchain, sdk, fileSize, contents, exportedBy, exportedOn, identifier,
             minimumOS, cpuFeatures, exportedFrom, existing
    }

    private enum Row: Equatable {
        case header(TransferSummary)
        case value(Field, String, String)
        /// A long value, a path or an identifier, under its name.
        case identifier(Field, String, String)
        case problem(String)
        case note(String)
        case name
    }

    private enum SectionID: Hashable { case summary, details, requirements, name, problems, notes }
    private struct Section {
        var id: SectionID
        var header: String?
        var footer: String?
        var rows: [Row]
    }

    private struct Item: Hashable {
        let section: SectionID
        let field: Field?
        let text: String?
        let occurrence: Int
    }

    private struct ItemContent: Equatable {
        let id: Item
        let row: Row
    }

    private lazy var dataSource = TableDataSource<SectionID, Item, ItemContent>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, item in
        self?.cell(for: item.row)
    }

    private func updateRows() {
        dataSource.headerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.header }
        dataSource.footerTitle = { [weak self] id in self?.sections.first { $0.id == id }?.footer }
        dataSource.update(sections.map { section in
            var occurrences: [String: Int] = [:]
            let rows = section.rows.map { row in
                let field: Field?
                let text: String?
                switch row {
                case let .value(id, _, _), let .identifier(id, _, _): field = id; text = nil
                case let .problem(value), let .note(value): field = nil; text = value
                case .header, .name: field = nil; text = nil
                }
                let occurrence = text.map { occurrences[$0, default: 0] } ?? 0
                if let text {
                    occurrences[text] = occurrence + 1
                }
                return ItemContent(
                    id: Item(section: section.id, field: field, text: text, occurrence: occurrence),
                    row: row,
                )
            }
            return (section.id, rows)
        })
    }

    private let file: TransferFile
    private var inspection: TransferInspection?
    private var sections: [Section] = []
    private var loader: Task<Void, Never>?
    private var isStarting = false

    private lazy var importItem: UIBarButtonItem = .init(
        title: String(localized: "Import"),
        primaryAction: UIAction { [weak self] _ in self?.startImport() },
    ).then {
        $0.style = .done
        $0.isEnabled = false
    }

    private lazy var nameField: UITextField = .init().then {
        $0.font = .preferredFont(forTextStyle: .body)
        $0.adjustsFontForContentSizeCategory = true
        $0.clearButtonMode = .whileEditing
        $0.autocapitalizationType = .words
        $0.autocorrectionType = .no
        $0.returnKeyType = .done
        $0.placeholder = String(localized: "Project Name")
        $0.accessibilityLabel = String(localized: "Project Name")
        $0.addAction(UIAction { [weak self] _ in self?.updateImportItem() }, for: .editingChanged)
        $0.addAction(
            UIAction { action in (action.sender as? UITextField)?.resignFirstResponder() },
            for: .editingDidEndOnExit,
        )
    }

    init(file: TransferFile) {
        self.file = file
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(file:)")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.kindTitle(file.kind)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = importItem
        tableView.keyboardDismissMode = .onDrag
        tableView.backgroundView = LoadingView()
        updateRows()
        inspect()
    }

    // MARK: - Reading

    private func inspect() {
        dataSource.beginLoad()
        loader = Task { [weak self, file] in
            guard let descriptor = file.duplicate() else {
                self?.show(String(cString: strerror(errno)))
                return
            }
            do {
                let inspection = try await ApelinService.app.transferInspect(
                    .file(DescriptorSlot(index: 0)),
                    fileName: file.fileName,
                    descriptors: [descriptor],
                )
                guard !Task.isCancelled else { return }
                self?.show(inspection)
            } catch {
                guard !Task.isCancelled else { return }
                self?.show(ToolchainController.unavailableText(error))
            }
        }
    }

    private func show(_ failure: String) {
        sections = []
        tableView.backgroundView = EmptyStateView(symbolName: "exclamationmark.triangle", text: failure)
        updateRows()
        updateImportItem()
    }

    private func show(_ inspection: TransferInspection) {
        self.inspection = inspection
        let summary = inspection.summary
        title = Self.kindTitle(summary.kind)
        if summary.kind == .project, nameField.text?.isEmpty != false {
            nameField.text = inspection.suggestedName ?? summary.project?.name ?? summary.name
        }

        var sections = [Section(id: .summary, rows: [.header(summary)])]
        sections.append(Section(id: .details, rows: details(of: summary, fileSize: inspection.fileSize)))
        let requirements = requirements(of: summary)
        if !requirements.isEmpty {
            sections.append(Section(id: .requirements, header: String(localized: "Requirements"), rows: requirements))
        }
        if summary.kind == .project, inspection.importable {
            sections.append(Section(
                id: .name,
                header: String(localized: "Name on This Device"),
                footer: String(localized: """
                The imported project has a new ID and no saved approvals. In Strict mode, the agent asks for approval before its first build or installation.
                """),
                rows: [.name],
            ))
        }
        if !inspection.problems.isEmpty {
            sections.append(Section(
                id: .problems,
                header: String(localized: "Unable to Import"),
                rows: inspection.problems.map(Row.problem),
            ))
        }
        var notes = inspection.notes.map(Row.note)
        if let existing = inspection.existingID {
            notes.insert(.identifier(.existing, String(localized: "Already on This Device"), existing), at: 0)
        }
        if !notes.isEmpty {
            sections.append(Section(id: .notes, header: String(localized: "Notes"), rows: notes))
        }
        if summary.kind == .toolchain, inspection.importable {
            sections[sections.count - 1].footer = String(localized: """
            A toolchain holds programs that run on this device. Import only one you exported yourself. \
            It is installed, then checked by compiling and running a program for each language, \
            and set up only if that passes.
            """)
        }
        self.sections = sections
        tableView.backgroundView = nil
        updateRows()
        updateImportItem()
    }

    private func details(of summary: TransferSummary, fileSize: Int64) -> [Row] {
        var rows: [Row] = []
        switch summary.kind {
        case .toolchain:
            if let toolchain = summary.toolchain {
                let record = toolchain.record
                rows.append(.value(.version, String(localized: "Version"), record.version))
                let languages = ToolchainDetailController.languages(of: record)
                if !languages.isEmpty {
                    rows.append(.value(.languages, String(localized: "Languages"), languages))
                }
                if let swift = record.swiftRequirements, record.components.contains(where: { $0.kind == .swift }) {
                    rows.append(.value(.swiftVersion, String(localized: "Swift Version"), swift.version))
                }
                if let newest = record.newestSDK {
                    rows.append(.value(.newestSDK, String(localized: "Newest Supported SDK"), newest))
                }
                rows.append(.value(.appleProduct, String(localized: "Apple Product ID"), toolchain.productID))
            }
        case .sdk:
            if let record = summary.sdk?.record {
                rows.append(.value(.version, String(localized: "Version"), record.version))
                rows.append(.value(.name, String(localized: "Name"), record.canonicalName))
                let architectures = SDKDetailController.architectures(of: record)
                if !architectures.isEmpty {
                    rows.append(.value(
                        .architectures,
                        String(localized: "Architectures"),
                        architectures.joined(separator: ", "),
                    ))
                }
                if let swift = SDKDetailController.swiftVersion(of: record) {
                    rows.append(.value(.swiftInterfaces, String(localized: "Swift Interfaces"), swift))
                }
            }
        case .project:
            if let project = summary.project {
                if let template = project.templateID {
                    let version = project.templateVersion.map { " \($0)" } ?? ""
                    rows.append(.value(.template, String(localized: "Template"), template + version))
                }
                rows.append(.value(
                    .gitHistory,
                    String(localized: "Git History"),
                    project.includesRepository ? String(localized: "Included") : String(localized: "None"),
                ))
                if let remote = project.remoteURL {
                    rows.append(.identifier(.remote, String(localized: "Remote"), remote))
                }
                if let toolchain = project.toolchainID {
                    rows.append(.identifier(.toolchain, String(localized: "Toolchain"), toolchain))
                }
                if let sdk = project.sdkID {
                    rows.append(.identifier(.sdk, String(localized: "Bound SDK"), sdk))
                }
            }
        }
        let size = ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        rows.append(.value(.fileSize, String(localized: "File Size"), size))
        let unpacked = ByteCountFormatter.string(fromByteCount: summary.payloadBytes, countStyle: .file)
        rows.append(.value(
            .contents,
            String(localized: "Contents"),
            String(localized: "\(summary.fileCount.formatted()) files, \(unpacked)"),
        ))
        rows.append(.value(.exportedBy, String(localized: "Exported By"), summary.createdBy))
        rows.append(.value(
            .exportedOn,
            String(localized: "Exported On"),
            summary.created.formatted(date: .abbreviated, time: .shortened),
        ))
        rows.append(.identifier(.identifier, String(localized: "Identifier"), summary.id))
        return rows
    }

    private func requirements(of summary: TransferSummary) -> [Row] {
        guard let toolchain = summary.toolchain else { return [] }
        let record = toolchain.record
        var rows: [Row] = []
        if let swift = record.swiftRequirements, record.components.contains(where: { $0.kind == .swift }) {
            rows.append(.value(.minimumOS, String(localized: "Minimum iOS Version"), swift.minimumHost))
        }
        let features = Array(
            Set((record.swiftRequirements?.cpuFeatures ?? []) + (record.clangModuleCPUFeatures ?? [])),
        ).sorted()
        if !features.isEmpty {
            rows.append(.value(.cpuFeatures, String(localized: "CPU Features"), features.joined(separator: ", ")))
        }
        rows.append(.value(
            .exportedFrom,
            String(localized: "Exported From"),
            "\(toolchain.bootstrap) · \(toolchain.architecture)",
        ))
        return rows
    }

    private func updateImportItem() {
        guard let inspection, inspection.importable, !isStarting else {
            importItem.isEnabled = false
            return
        }
        if inspection.summary.kind == .project {
            let name = nameField.text?.trimmingCharacters(in: .whitespaces) ?? ""
            importItem.isEnabled = !name.isEmpty
        } else {
            importItem.isEnabled = true
        }
    }

    static func kindTitle(_ kind: TransferKind) -> String {
        switch kind {
        case .toolchain: String(localized: "Toolchain")
        case .sdk: String(localized: "iPhoneOS SDK")
        case .project: String(localized: "Project")
        }
    }

    static func symbol(_ kind: TransferKind) -> String {
        switch kind {
        case .toolchain: "hammer"
        case .sdk: "shippingbox"
        case .project: "folder"
        }
    }

    // MARK: - Importing

    private func startImport() {
        guard let inspection, inspection.importable, !isStarting else { return }
        let kind = inspection.summary.kind
        let name = kind == .project ? nameField.text?.trimmingCharacters(in: .whitespaces) : nil
        guard let descriptor = file.duplicate() else {
            presentNotice(title: "Unable to Import", message: "This file could not be read. Choose the file again.")
            return
        }
        nameField.resignFirstResponder()
        isStarting = true
        updateImportItem()
        Task { [weak self, file] in
            do {
                let handle = try await ApelinService.app.transferImport(
                    TransferImportRequest(
                        source: .file(DescriptorSlot(index: 0)),
                        fileName: file.fileName,
                        kind: kind,
                        projectName: name,
                    ),
                    descriptors: [descriptor],
                )
                self?.showTask(handle, kind: kind)
            } catch {
                guard let self else { return }
                isStarting = false
                updateImportItem()
                if kind == .project, (error as? ApelinError)?.code == .conflict {
                    presentNotice(title: "Name Already Used", message: error.readableMessage) { [weak self] in
                        self?.nameField.becomeFirstResponder()
                        self?.nameField.selectAll(nil)
                    }
                } else {
                    presentNotice(title: "Unable to Import", message: error.readableMessage)
                }
            }
        }
    }

    /// The task page takes this one's place, so going back does not offer
    /// the same file again.
    private func showTask(_ handle: TaskHandle, kind: TransferKind) {
        let title: String
        let doneTitle: String
        switch kind {
        case .toolchain:
            title = String(localized: "Importing Toolchain…")
            doneTitle = String(localized: "Toolchain Imported")
        case .sdk:
            title = String(localized: "Importing SDK…")
            doneTitle = String(localized: "SDK Imported")
        case .project:
            title = String(localized: "Importing Project…")
            doneTitle = String(localized: "Project Imported")
        }
        let page = EnvironmentTaskController(
            handle: handle,
            work: .transferImport(kind),
            title: title,
            doneTitle: doneTitle,
        )
        page.onFinish = {
            NotificationCenter.default.post(name: TransferOpener.environmentChanged, object: nil)
        }
        guard let navigation = navigationController else { return }
        var stack = navigation.viewControllers
        let isRoot = stack.first === self
        if let index = stack.firstIndex(of: self) {
            stack.removeSubrange(index...)
        }
        if isRoot {
            page.navigationItem.leftBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "xmark"),
                primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) },
            ).then { $0.accessibilityLabel = String(localized: "Close") }
        }
        navigation.setViewControllers(stack + [page], animated: true)
    }

    // MARK: - Table

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.valueCell()
        switch row {
        case let .header(summary):
            content = .subtitleCell()
            content.image = UIImage(systemName: Self.symbol(summary.kind))
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title1)
            content.imageProperties.tintColor = .tintColor
            content.imageToTextPadding = 16
            content.text = summary.name
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            content.secondaryText = Self.kindTitle(summary.kind)
            content.secondaryTextProperties.color = .secondaryLabel
            content.textToSecondaryTextVerticalPadding = 4
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        case let .value(_, name, value):
            content.text = name
            content.secondaryText = value
        case let .identifier(_, name, value):
            content = .subtitleCell()
            content.text = name
            content.secondaryText = value
            content.secondaryTextProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
                weight: .regular,
            )
            content.secondaryTextProperties.color = .secondaryLabel
            content.textToSecondaryTextVerticalPadding = 4
        case let .problem(text):
            content = .cell()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.textProperties.color = .systemRed
            content.image = UIImage(systemName: "xmark.octagon.fill")
            content.imageProperties.tintColor = .systemRed
        case let .note(text):
            content = .cell()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.image = UIImage(systemName: "info.circle")
            content.imageProperties.tintColor = .secondaryLabel
        case .name:
            cell.contentView.addSubview(nameField)
            nameField.snp.remakeConstraints {
                $0.edges.equalTo(cell.contentView.layoutMarginsGuide)
                $0.height.greaterThanOrEqualTo(32)
            }
            return cell
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        false
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        let text: String
        guard let row = dataSource.value(at: indexPath)?.row else { return nil }
        switch row {
        case let .value(_, _, value), let .identifier(_, _, value), let .problem(value), let .note(value): text = value
        case .header, .name: return nil
        }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }
}
