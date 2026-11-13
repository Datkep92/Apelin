import SPIndicator
import UIKit

/// A recorded call made here in the app rather than by the page: the same
/// address, method, headers, cookies and body, sent by Apelin itself, with what
/// the server answered.
///
/// This is the site's own API used straight — what the site's interface asked
/// its server, asked again with no page of the site being driven.
final class WebAPICallResultController: TableController {
    private struct Row {
        /// The value's own name; nil when the value is a block of text.
        let title: String?
        let value: String
        /// A value that is not worth putting on the clipboard reads as it is.
        let copies: Bool
    }

    private struct Section {
        let header: String?
        let rows: [Row]
    }

    /// What the attempt so far got.
    private enum Outcome {
        /// Being asked now, or not asked yet.
        case calling
        /// The app does not make this call, and the reason it does not.
        case refused(String)
        case answered(status: Int, headers: [(name: String, value: String)], body: String, milliseconds: Int)
        case failed(String)
    }

    /// Headers the app's own request writes: the page's own value for one of
    /// these would only contradict it, and the session attaches the cookies.
    private static let managedHeaders: Set<String> = [
        "host", "connection", "content-length", "cookie", "accept-encoding",
        "keep-alive", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade",
    ]

    /// Methods that carry no body, whatever a page reported.
    private static let withoutBody: Set<String> = ["GET", "HEAD"]

    private static let timeout: TimeInterval = 60

    private let call: WebAPICall
    private var outcome: Outcome = .calling
    private var sections: [Section] = []
    private var hasRun = false
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(call: WebAPICall) {
        self.call = call
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(call:)")
    }

    deinit {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "\(call.method) \(call.host)"
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Call Again"),
            primaryAction: UIAction { [weak self] _ in self?.run() },
        )
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Asked once, on the way in: coming back to the answer does not ask the
        // site again.
        guard !hasRun else { return }
        hasRun = true
        run()
    }

    // MARK: - What is shown

    private func reload() {
        sections = makeSections()
        tableView.reloadData()
    }

    private func makeSections() -> [Section] {
        var summary = [
            Row(title: String(localized: "Method"), value: call.method, copies: true),
            Row(title: String(localized: "Web Address"), value: call.url, copies: true),
        ]
        switch outcome {
        case .calling:
            summary.append(Row(title: String(localized: "Status"),
                               value: String(localized: "Calling…"),
                               copies: false))
        case let .refused(reason):
            summary.append(Row(title: nil, value: reason, copies: false))
        case let .answered(status, _, _, milliseconds):
            summary.append(Row(title: String(localized: "Status"), value: "\(status)", copies: false))
            summary.append(Row(title: String(localized: "Duration"),
                               value: WebAPICall.durationText(milliseconds),
                               copies: false))
        case let .failed(message):
            summary.append(Row(title: String(localized: "Error"), value: message, copies: true))
        }

        var sections = [Section(header: nil, rows: summary)]
        guard case let .answered(_, headers, body, _) = outcome else { return sections }
        sections.append(Section(header: String(localized: "Response Headers"),
                                rows: headers.isEmpty
                                    ? [Row(title: nil, value: String(localized: "None"), copies: false)]
                                    : headers.map { Row(title: $0.name, value: $0.value, copies: true) }))
        sections.append(Section(header: String(localized: "Response"),
                                rows: [Row(title: nil,
                                           value: body.isEmpty ? String(localized: "Nothing came back.") : body,
                                           copies: !body.isEmpty)]))
        return sections
    }

    /// A body cut for the screen; a copy takes the whole of it.
    private static func shown(_ text: String) -> String {
        text.count > 4000 ? String(text.prefix(4000)) + "..." : text
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
        SPIndicator.present(title: String(localized: "Copied"), preset: .done, haptic: .success)
    }

    // MARK: - The call

    private func run() {
        task?.cancel()
        task = nil
        outcome = .calling
        reload()
        guard let url = URL(string: call.url) else {
            outcome = .refused(String(localized: "This address cannot be read."))
            reload()
            return
        }
        // Only a secure address is called from here: the cookies it carries are
        // the reader's, and they are not sent over a connection that is not
        // encrypted. An http call still has the route through a chat.
        guard url.scheme?.lowercased() == "https" else {
            outcome = .refused(String(localized: "This address is not secure (http), so the app does not call it. Use Call It Directly: Apelin calls it from the device instead."))
            reload()
            return
        }
        send(request(for: url))
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.timeoutInterval = Self.timeout
        for header in call.sortedRequestHeaders where !Self.managedHeaders.contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if let cookies = call.cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }
        if let body = call.requestBody, !body.isEmpty,
           !Self.withoutBody.contains(call.method.uppercased()) {
            request.httpBody = Data(body.utf8)
        }
        for header in Self.browserHeaders(for: call)
        where request.value(forHTTPHeaderField: header.name) == nil {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// What a browser adds to a call without the page asking. A page's own
    /// script cannot set any of these, so a call it reported does not carry
    /// them, and a site that reads one answers differently without it.
    private static func browserHeaders(for call: WebAPICall) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = [("Accept", "*/*")]
        let languages = Locale.preferredLanguages.prefix(3).joined(separator: ", ")
        if !languages.isEmpty {
            headers.append(("Accept-Language", languages))
        }
        if let agent = call.userAgent, !agent.isEmpty {
            headers.append(("User-Agent", agent))
        }
        guard let page = URL(string: call.page), let host = page.host, let scheme = page.scheme,
              !call.page.isEmpty else { return headers }
        headers.append(("Referer", call.page))
        if let target = URL(string: call.url),
           target.scheme != scheme || target.host != host {
            headers.append(("Origin", "\(scheme)://\(host)"))
        }
        return headers
    }

    private func send(_ request: URLRequest) {
        // The page's own cookies are attached here by hand, so the session keeps
        // none of its own and reads no stored cache: the call is the one that
        // was recorded, not one this app has made before.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.timeout
        let session = URLSession(configuration: configuration)
        self.session = session

        let started = Date()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            let answer: Outcome
            if let error {
                // A call the next one replaced says nothing at all.
                guard (error as NSError).code != NSURLErrorCancelled else { return }
                answer = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse {
                answer = .answered(status: http.statusCode,
                                   headers: Self.headers(from: http),
                                   body: Self.body(from: data),
                                   milliseconds: milliseconds)
            } else {
                answer = .failed(String(localized: "Failed"))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.task = nil
                self.outcome = answer
                self.reload()
            }
        }
        self.task = task
        task.resume()
    }

    private static func headers(from response: HTTPURLResponse) -> [(name: String, value: String)] {
        let pairs: [(name: String, value: String)] = response.allHeaderFields.compactMap { entry in
            guard let name = entry.key.base as? String else { return nil }
            return (name: name, value: (entry.value as? String) ?? String(describing: entry.value))
        }
        return pairs.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func body(from data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
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
        if let title = row.title {
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
        cell.selectionStyle = row.copies ? .default : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = sections[indexPath.section].rows[indexPath.row]
        guard row.copies else { return }
        copyToPasteboard(row.value)
    }
}
