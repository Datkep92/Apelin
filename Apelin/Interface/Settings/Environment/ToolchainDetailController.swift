import ApelinCore
import ApelinProtocol
import SnapKit
import Then
import UIKit

/// Toolchain ▸ one toolchain: what it is, what was checked about it, where
/// it lives, and removing it.
final class ToolchainDetailController: TableController {
    /// Told once the toolchain is removed, so the list reads itself again.
    var onRemove: (() -> Void)?

    private enum Field: Hashable {
        case version, languages, swiftVersion, minimumOS, architectures, isDefault, files, appleProduct, selfTests
    }

    private enum Row: Equatable {
        case value(Field, String, String)
        case selfTests([ToolchainSelfTestResult])
        var id: Field {
            switch self {
            case let .value(id, _, _): id
            case .selfTests: .selfTests
            }
        }
    }

    private lazy var dataSource = TableDataSource<Int, Field, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let record: ToolchainRecord
    private let isDefault: Bool

    /// `…` in the bar: Export, anchoring the share sheet that follows.
    private lazy var moreItem: UIBarButtonItem = .init(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [
            UIAction(title: String(localized: "Show in Fila"), image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.revealInFila(path: self?.record.path ?? "")
            },
            UIAction(
                title: String(localized: "Export…"),
                image: UIImage(systemName: "square.and.arrow.up"),
            ) { [weak self] _ in
                self?.export()
            },
            UIAction(
                title: String(localized: "Remove"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in self?.confirmRemoval() },
        ]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    init(record: ToolchainRecord, isDefault: Bool) {
        self.record = record
        self.isDefault = isDefault
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:isDefault:)")
    }

    static func name(of record: ToolchainRecord) -> String {
        String(localized: "Command Line Tools \(record.version)")
    }

    /// "C, C++, Objective-C, Swift": what its components compile.
    static func languages(of record: ToolchainRecord) -> String {
        record.components.compactMap { component -> String? in
            switch component.kind {
            case .c: String(localized: "C, C++, Objective-C")
            case .swift: String(localized: "Swift")
            case .auxiliary: nil
            }
        }.joined(separator: ", ")
    }

    /// `<productID> <url>`: the product is what Apple calls it.
    static func product(of record: ToolchainRecord) -> String? {
        record.origin?.split(separator: " ").first.map(String.init)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.name(of: record)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = moreItem

        var rows: [Row] = [.value(.version, String(localized: "Version"), record.version)]
        let languages = Self.languages(of: record)
        if !languages.isEmpty {
            rows.append(.value(.languages, String(localized: "Languages"), languages))
        }
        if let swift = record.swiftRequirements, record.components.contains(where: { $0.kind == .swift }) {
            rows.append(.value(.swiftVersion, String(localized: "Swift Version"), swift.version))
            rows.append(.value(.minimumOS, String(localized: "Minimum iOS Version"), swift.minimumHost))
        }
        let architectures = Array(Set((record.selfTests ?? []).map(\.architecture))).sorted()
        if !architectures.isEmpty {
            rows.append(.value(
                .architectures,
                String(localized: "Architectures"),
                architectures.joined(separator: ", "),
            ))
        }
        rows.append(.value(
            .isDefault,
            String(localized: "Default"),
            isDefault ? String(localized: "Yes") : String(localized: "No"),
        ))
        if let tests = record.selfTests, !tests.isEmpty {
            rows.append(.selfTests(tests))
        }
        if let count = record.fileCount {
            rows.append(.value(.files, String(localized: "Files"), count.formatted()))
        }
        if let product = Self.product(of: record) {
            rows.append(.value(.appleProduct, String(localized: "Apple Product ID"), product))
        }
        // the package and where it lies, as Irisin ends its settings: small
        // grey lines under the list, not rows
        let lines = [record.packageID, record.path].compactMap(\.self)
        tableView.tableFooterView = lines.isEmpty ? nil : TableFootnoteView(lines: lines)
        dataSource.update([(0, rows)])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (tableView.tableFooterView as? TableFootnoteView)?.fit(in: tableView)
    }

    // MARK: - Table

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        cell.selectionStyle = .none
        switch row {
        case let .value(_, name, value):
            content.text = name
            content.secondaryText = value
        case let .selfTests(tests):
            let passed = tests.filter(\.passed).count
            content.text = String(localized: "Self-Tests")
            content.secondaryText = String(localized: "\(passed) of \(tests.count) Passed")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .selfTests? = dataSource.value(at: indexPath) {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .selfTests(tests):
            navigationController?.pushViewController(SelfTestsController(record: record, tests: tests), animated: true)
        case .value:
            break
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        let text: String
        guard let row = dataSource.value(at: indexPath) else { return nil }
        switch row {
        case let .value(_, _, value): text = value
        default: return nil
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

    private func confirmRemoval() {
        presentConfirmation(
            title: "Remove the Toolchain?",
            message: "Projects using this toolchain cannot build until you download and set it up again.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove()
        }
    }

    /// A `.apetc` of this toolchain, for the user's other devices.
    private func export() {
        TransferExporter.confirmAndExport(
            kind: .toolchain,
            id: record.id,
            name: Self.name(of: record),
            from: self,
            anchor: moreItem,
        )
    }

    /// Removal is quick: Fila's progress card, not the setup page.
    private func remove() {
        Task { [weak self, record] in
            guard let self else { return }
            do {
                let outcome = try await ProgressCard.run(
                    title: String(localized: "Removing Toolchain"),
                    message: Self.name(of: record),
                    cancellable: false,
                    from: self,
                ) { update in
                    let handle = try await ApelinService.app.toolchainRemove(id: record.id)
                    var progress = EnvironmentTaskProgress(work: .toolchainRemoval)
                    for try await event in ApelinService.app.events(of: handle) {
                        progress.apply(event)
                        if let detail = progress.detail, !detail.isEmpty {
                            update(ProgressCard.Status(subtitle: detail))
                        }
                    }
                    return progress
                }
                onRemove?()
                if outcome.state == .succeeded {
                    navigationController?.popViewController(animated: true)
                } else {
                    presentNotice(title: "Unable to Remove", message: outcome.outcomeMessage)
                }
            } catch {
                presentNotice(title: "Unable to Remove", message: error.readableMessage)
            }
        }
    }
}

/// Toolchain ▸ Self-Tests: each language and architecture the installed
/// tools were checked with, and what the check found.
private final class SelfTestsController: TableController {
    private lazy var dataSource = TableDataSource<Int, String, ToolchainSelfTestResult>(
        tableView: tableView,
        identifier: { $0.language + "\u{1f}" + $0.architecture },
    ) { [weak self] _, _, test in
        self?.cell(for: test)
    }

    private func updateRows() {
        dataSource.footerTitle = { [weak self] _ in self?.footer() }
        dataSource.update([(0, tests)])
    }

    private let record: ToolchainRecord
    private var tests: [ToolchainSelfTestResult]

    init(record: ToolchainRecord, tests: [ToolchainSelfTestResult]) {
        self.record = record
        self.tests = tests
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:tests:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Self-Tests")
        tableView.allowsSelection = false
        updateRows()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Run Again"),
                    image: UIImage(systemName: "arrow.clockwise"),
                ) { [weak self] _ in self?.runAgain() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
    }

    /// The installed tools tested once more, on the task page; back here the
    /// list shows what the registry now keeps.
    private func runAgain() {
        Task { [weak self, record] in
            do {
                let handle = try await ApelinService.app.toolchainSelfTest(id: record.id)
                guard let self else { return }
                let page = EnvironmentTaskController(
                    handle: handle,
                    work: .toolchainSelfTest,
                    title: String(localized: "Running Self-Tests"),
                    doneTitle: String(localized: "Self-Tests Done"),
                )
                page.onFinish = { [weak self] in self?.reload() }
                navigationController?.pushViewController(page, animated: true)
            } catch {
                self?.presentNotice(title: "Unable to Start Self-Tests", message: error.readableMessage)
            }
        }
    }

    private func reload() {
        dataSource.beginLoad()
        Task { [weak self, record] in
            guard let status = try? await ApelinService.app.toolchainStatus(),
                  let fresh = status.toolchains.first(where: { $0.id == record.id })?.selfTests,
                  let self
            else { return }
            tests = fresh
            updateRows()
        }
    }

    private func footer() -> String? {
        String(localized: """
        Checked after installation by compiling, linking, signing and running a program \
        for each language and architecture.
        """)
    }

    private func cell(for test: ToolchainSelfTestResult) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let seconds = String(localized: "\(test.seconds.formatted(.number.precision(.fractionLength(2)))) s")
        // one line for a pass, its time at the end; only a failure says
        // what the check found, under it
        var content = test.passed || test.detail.isEmpty
            ? UIListContentConfiguration.valueCell()
            : UIListContentConfiguration.subtitleCell()
        content.text = "\(test.language) · \(test.architecture)"
        content.secondaryText = test.passed || test.detail.isEmpty ? seconds : test.detail
        content.secondaryTextProperties.color = test.passed ? .secondaryLabel : .systemRed
        content.secondaryTextProperties.numberOfLines = test.passed ? 1 : 3
        content.image = UIImage(systemName: test.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
        content.imageProperties.tintColor = test.passed ? .systemGreen : .systemRed
        cell.contentConfiguration = content
        // the mark is drawn; say it
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = test.passed
            ? String(localized: "Passed") + ", " + seconds
            : String(localized: "Failed") + ", " + (content.secondaryText ?? "")
        return cell
    }
}
