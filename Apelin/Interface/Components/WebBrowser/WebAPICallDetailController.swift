import SPIndicator
import UIKit

/// One recorded API call in full: what it asked, what it answered, the cookies
/// it carried, and the whole call as a `curl` command — so the same API can be
/// called from outside the page instead of the site's interface being driven.
final class WebAPICallDetailController: TableController {
    private struct Row {
        /// The value's own name; nil when the value is a block of text.
        let title: String?
        let value: String
        /// A value that is not worth putting on the clipboard reads as it is.
        let copies: Bool
        /// The one row that does something rather than showing a value.
        var handoff = false
        /// The one row that makes the call here in the app.
        var runs = false
    }

    private struct Section {
        let header: String?
        let rows: [Row]
    }

    private let call: WebAPICall
    private var sections: [Section] = []

    init(call: WebAPICall) {
        self.call = call
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(call:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(call.method) \(call.host)"
        navigationItem.backButtonDisplayMode = .minimal
        sections = makeSections()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Copy as cURL"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                copyToPasteboard(call.curlCommand)
            },
        )
    }

    private func makeSections() -> [Section] {
        var summary = [
            Row(title: nil, value: String(localized: "Call Now in App"), copies: false, runs: true),
            Row(title: nil, value: String(localized: "Call It Directly"), copies: false, handoff: true),
            Row(title: String(localized: "Method"), value: call.method, copies: true),
            Row(title: String(localized: "Web Address"), value: call.url, copies: true),
            Row(title: String(localized: "Status"), value: call.statusText ?? String(localized: "Failed"), copies: false),
        ]
        if let duration = call.durationText {
            summary.append(Row(title: String(localized: "Duration"), value: duration, copies: false))
        }
        if let error = call.error {
            summary.append(Row(title: String(localized: "Error"), value: error, copies: true))
        }
        summary.append(Row(title: String(localized: "Time"),
                           value: call.at.formatted(date: .abbreviated, time: .standard),
                           copies: false))
        if !call.page.isEmpty {
            summary.append(Row(title: String(localized: "Page"), value: call.page, copies: true))
        }

        var sections = [Section(header: nil, rows: summary)]
        sections.append(Section(header: String(localized: "Request Headers"),
                                rows: rows(from: call.sortedRequestHeaders)))
        sections.append(Section(header: String(localized: "Cookies"),
                                rows: rows(from: call.cookiePairs)))
        if let body = call.requestBody {
            sections.append(Section(header: String(localized: "Request Body"),
                                    rows: [Row(title: nil, value: body, copies: true)]))
        }
        if let response = call.response {
            sections.append(Section(header: String(localized: "Response"),
                                    rows: [Row(title: nil, value: response, copies: true)]))
        }
        return sections
    }

    /// Header and cookie names with their values, or the one row that says the
    /// call carried none.
    private func rows(from pairs: [(name: String, value: String)]) -> [Row] {
        guard !pairs.isEmpty else {
            return [Row(title: nil, value: String(localized: "None"), copies: false)]
        }
        return pairs.map { Row(title: $0.name, value: $0.value, copies: true) }
    }

    /// A body cut for the screen; a copy takes the whole of it.
    private static func shown(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "..." : text
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        SPIndicator.present(title: String(localized: "Copied"), preset: .done, haptic: .success)
    }

    /// Hands the call to a chat, so Apelin makes it itself: the site's own API
    /// called with the headers and the cookies it carried, instead of its pages
    /// being driven again.
    private func handOffToChat() {
        let link = ApelinLink.chat(prompt: call.handoffPrompt)
        _ = ApelinLinkRouter.open(link.url, in: view.window?.windowScene)
    }

    // MARK: - Table

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == sections.count - 1 else { return nil }
        return String(localized: "Tap a value to copy it.")
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        if row.runs {
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.value
            content.textProperties.color = .tintColor
            content.secondaryText = String(localized: "Calls the API here in the app, with the cookies it carried, and shows the answer.")
            cell.contentConfiguration = content
        } else if row.handoff {
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.value
            content.textProperties.color = .tintColor
            content.secondaryText = String(localized: "Opens a new chat with this call, ready to send.")
            cell.contentConfiguration = content
        } else if let title = row.title {
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = title
            content.secondaryText = row.value
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .callout)
            cell.contentConfiguration = content
        } else {
            var content = UIListContentConfiguration.cell()
            content.text = Self.shown(row.value)
            content.textProperties.numberOfLines = 0
            content.textProperties.font = .monospacedSystemFont(
                ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize,
                weight: .regular,
            )
            cell.contentConfiguration = content
        }
        cell.selectionStyle = row.copies || row.handoff || row.runs ? .default : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        if row.runs {
            callInApp()
        } else if row.handoff {
            handOffToChat()
        } else if row.copies {
            copyToPasteboard(row.value)
        }
    }

    /// Opens the call made here in the app: the same request sent by Apelin
    /// itself, with what the server answers on the screen that follows.
    private func callInApp() {
        let result = WebAPICallResultController(call: call)
        if let navigation = navigationController {
            navigation.pushViewController(result, animated: true)
        } else {
            presentPageAsFormSheet(result)
        }
    }
}
