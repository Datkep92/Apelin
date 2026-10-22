import ApelinCore
import ApelinProtocol
import Then
import UIKit

/// SDKs ▸ one SDK: what it was identified as, what the check warned about,
/// and under the list, in small grey lines, where it came from and where
/// it lies. Removing it is in the menu at the top.
final class SDKDetailController: TableController {
    /// Told once the SDK is removed, so the list reads itself again.
    var onRemove: (() -> Void)?

    private enum Field: Hashable { case version, name, architectures, swiftInterfaces }
    private struct Row: Equatable {
        let id: Field
        let name: String
        let value: String
    }

    private lazy var dataSource = TableDataSource<Int, Field, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let record: SDKRecord

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

    init(record: SDKRecord) {
        self.record = record
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(record:)")
    }

    /// `iphoneos27.0` → `iOS 27.0`.
    static func displayName(of record: SDKRecord) -> String {
        let platform = record.canonicalName.lowercased().hasPrefix("iphoneos") ? "iOS" : record.canonicalName
        return "\(platform) \(record.version)"
    }

    /// `arm64e-ios`, `arm64e.x1-ios` → `arm64e`, `arm64e.x1`.
    static func architectures(of record: SDKRecord) -> [String] {
        record.targets.map { target in
            target.hasSuffix("-ios") ? String(target.dropLast(4)) : target
        }
    }

    /// "Apple Swift version 6.4 effective-5.10 (…)" → "6.4".
    static func swiftVersion(of record: SDKRecord) -> String? {
        guard let swift = record.swiftCompilerVersion else { return nil }
        let words = swift.split(separator: " ")
        guard let index = words.firstIndex(of: "version"), words.indices.contains(index + 1) else { return swift }
        return String(words[index + 1])
    }

    /// The architectures without their variants: `arm64e.x1` is `arm64e`.
    static func baseArchitectures(of record: SDKRecord) -> [String] {
        var seen: [String] = []
        for architecture in architectures(of: record) {
            let base = String(architecture.prefix { $0 != "." })
            if !seen.contains(base) {
                seen.append(base)
            }
        }
        return seen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.displayName(of: record)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = moreItem

        var about: [Row] = [
            Row(id: .version, name: String(localized: "Version"), value: record.version),
            Row(id: .name, name: String(localized: "Name"), value: record.canonicalName),
        ]
        let architectures = Self.architectures(of: record)
        if !architectures.isEmpty {
            about.append(Row(
                id: .architectures,
                name: String(localized: "Architectures"),
                value: architectures.joined(separator: ", "),
            ))
        }
        if let swift = Self.swiftVersion(of: record) {
            about.append(Row(id: .swiftInterfaces, name: String(localized: "Swift Interfaces"), value: swift))
        }
        // the check's warnings stay in the record; none of them stops a build
        dataSource.update([(0, about)])
        let lines = [record.origin.map(Self.describe(origin:)), record.id, record.digest, record.path]
        tableView.tableFooterView = TableFootnoteView(lines: lines.compactMap(\.self))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        (tableView.tableFooterView as? TableFootnoteView)?.fit(in: tableView)
    }

    /// `repository <url>#<branch>@<commit>`, `url <url>`, `file`,
    /// `inbox <path>`, in words.
    private static func describe(origin: String) -> String {
        let parts = origin.split(separator: " ", maxSplits: 1).map(String.init)
        let rest = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "inbox": return String(localized: "Imported from inbox: \(rest)")
        case "url": return rest
        case "repository": return rest
        case "file": return String(localized: "Imported from a file")
        default: return origin
        }
    }

    private func cell(for row: Row) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        content.text = row.name
        content.secondaryText = row.value
        cell.selectionStyle = .none
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        false
    }

    private func confirmRemoval() {
        presentConfirmation(
            title: "Remove the SDK?",
            message: "This deletes the SDK files. SDKs used by a project cannot be removed.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.remove()
        }
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let text = dataSource.value(at: indexPath)?.value else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = text
            }])
        })
    }

    /// A `.apesdk` of this SDK, for the user's other devices.
    private func export() {
        TransferExporter.confirmAndExport(
            kind: .sdk,
            id: record.id,
            name: Self.displayName(of: record),
            from: self,
            anchor: moreItem,
        )
    }

    private func remove() {
        Task { [weak self, record] in
            guard let self else { return }
            do {
                try await ProgressCard.run(
                    title: String(localized: "Removing SDK"),
                    message: Self.displayName(of: record),
                    cancellable: false,
                    from: self,
                ) { _ in
                    try await ApelinService.app.sdkRemove(id: record.id)
                }
                onRemove?()
                navigationController?.popViewController(animated: true)
            } catch {
                presentNotice(title: "Unable to Remove", message: error.readableMessage)
            }
        }
    }
}
