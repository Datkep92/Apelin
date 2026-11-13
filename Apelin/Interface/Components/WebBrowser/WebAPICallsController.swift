import SPIndicator
import UIKit

/// The API calls the pages in this browser made, newest first, with the switch
/// that keeps recording them and the way to clear what is kept.
///
/// Read here, or handed to a chat: the same call made again with the headers and
/// the cookies it carried is the site's own API called directly, instead of its
/// interface being driven page by page.
final class WebAPICallsController: TableController {
    private let store = WebAPICaptureStore.shared
    private let recording = UISwitch()

    /// Newest first, which is the page's own order reversed.
    private var calls: [WebAPICall] {
        Array(store.calls.reversed())
    }

    init() {
        super.init(style: .insetGrouped)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeChanged),
            name: WebAPICaptureStore.didChange,
            object: store,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "API Calls")
        navigationItem.backButtonDisplayMode = .minimal
        recording.isOn = store.isRecording
        recording.accessibilityLabel = String(localized: "Record API Calls")
        recording.addTarget(self, action: #selector(toggleRecording), for: .valueChanged)
        store.refresh()
        reload()
    }

    // MARK: - Table

    private func reload() {
        tableView.backgroundView = calls.isEmpty
            ? EmptyStateView(
                symbolName: "arrow.up.arrow.down",
                title: String(localized: "No API Calls Yet"),
                text: String(localized: "Open a page and use it; the calls it makes appear here."),
            )
            : nil
        tableView.reloadData()
    }

    override func numberOfSections(in _: UITableView) -> Int {
        2
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : calls.count + (calls.isEmpty ? 0 : 1)
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return String(localized: "Kept in this app only, with the cookies each call sent, so the same API can be called directly.")
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard indexPath.section == 1 else { return recordingCell() }
        guard indexPath.row < calls.count else { return clearCell() }
        return cell(for: calls[indexPath.row])
    }

    private func recordingCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Record API Calls")
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = recording
        return cell
    }

    private func clearCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Clear")
        content.textProperties.color = .systemRed
        cell.contentConfiguration = content
        return cell
    }

    private func cell(for call: WebAPICall) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.stackedValueCell()
        content.text = "\(call.method) \(call.path)"
        content.textProperties.numberOfLines = 2
        content.secondaryText = summary(of: call)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    /// What the row says under the call: who answered, how long it took, when.
    private func summary(of call: WebAPICall) -> String {
        var parts = [call.host, call.statusText ?? String(localized: "Failed")]
        if let duration = call.durationText { parts.append(duration) }
        parts.append(call.at.formatted(date: .omitted, time: .standard))
        return parts.joined(separator: " · ")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        guard indexPath.row < calls.count else {
            clearCalls()
            return
        }
        navigationController?.pushViewController(
            WebAPICallDetailController(call: calls[indexPath.row]),
            animated: true,
        )
    }

    // MARK: - Actions

    @objc private func storeChanged() {
        recording.isOn = store.isRecording
        reload()
    }

    @objc private func toggleRecording() {
        store.setRecording(recording.isOn)
    }

    private func clearCalls() {
        presentConfirmation(
            title: "Clear",
            message: "Every recorded call is deleted from this app. Pages keep working as they are.",
            confirmTitle: "Clear",
            destructive: true,
        ) { [weak self] in self?.store.clear() }
    }
}
