import Foundation
import KWWKAI

/// apelin_http_request: make an HTTP request (any method) to a public
/// http or https address and answer its status, headers and body. Like
/// apelin_web_fetch it refuses local-network hosts and credentials in the
/// address, and keeps no cookie, cache or credential. The body is read up to
/// 5 MB and answered 32 KB of text at a time. What the response says is
/// data the model reads, never instructions.
struct HTTPRequest: Sendable {
    static let pageBytes = 32 * 1024
    static let maximumBodyBytes = 5 * 1024 * 1024
    static let maximumRedirects = 5
    static let timeoutSeconds = 30

    static let shared = HTTPRequest()

    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Self.timeoutSeconds)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Apelin",
        ]
        session = URLSession(configuration: configuration, delegate: RedirectHold(), delegateQueue: nil)
    }

    func request(_ arguments: JSONValue) async throws -> HTTPResponse {
        let url = try Self.target(arguments.requireString("url"))
        let method = (arguments.argString("method") ?? "GET").uppercased()
        var headers: [String: String] = [:]
        if let raw = arguments["headers"] {
            if case .object(let obj) = raw {
                for (k, v) in obj {
                    if let s = v.stringValue { headers[k] = s }
                }
            }
        }
        let body: Data? = arguments.argString("body").map { Data($0.utf8) }
        let offset = max(0, arguments.argInt("offset") ?? 0)
        let session = session
        let result = try await Self.withinTimeout(url) {
            try await Self.load(url, method: method, headers: headers, body: body, session: session)
        }
        return try result.response(from: offset)
    }

    static func target(_ address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address) else {
            throw ToolArgumentError("url does not read as an address: \(address)")
        }
        if let refusal = refusal(url) {
            throw ToolArgumentError("not requested: \(refusal); apelin_http_request reads public http and https addresses")
        }
        return withoutFragment(url)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    private static func refusal(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "\(url.absoluteString) is not an http or https address"
        }
        guard url.user == nil, url.password == nil else {
            return "the address carries a user name or password"
        }
        guard let host = url.host, !host.isEmpty else {
            return "\(url.absoluteString) names no host"
        }
        return PublicHost.refusal(host)
    }

    private static func load(_ start: URL, method: String, headers: [String: String], body: Data?, session: URLSession) async throws -> FetchedHTTP {
        var url = start
        var currentMethod = method
        var currentBody = body
        for _ in 0 ... maximumRedirects {
            var request = URLRequest(url: url)
            request.httpMethod = currentMethod
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            request.httpBody = currentBody
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ToolDeniedError(message: "\(url.absoluteString) did not answer over HTTP")
            }
            if (300 ... 399).contains(response.statusCode), response.statusCode != 304,
               let location = response.value(forHTTPHeaderField: "Location") {
                bytes.task.cancel()
                guard let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw ToolDeniedError(message: "not followed: \(url.absoluteString) redirects to \(location), which does not read as an address")
                }
                if let refusal = refusal(next) {
                    throw ToolDeniedError(message: "not followed: \(url.absoluteString) redirects to \(next.absoluteString), but \(refusal)")
                }
                url = withoutFragment(next)
                // RFC: redirect usually converts to GET; keep simple: keep method for 307/308
                if response.statusCode == 307 || response.statusCode == 308 {
                    // keep
                } else {
                    currentMethod = "GET"
                    currentBody = nil
                }
                continue
            }
            return try await read(bytes, response: response, url: url)
        }
        throw ToolDeniedError(message: "not followed: \(start.absoluteString) redirects more than \(maximumRedirects) times")
    }

    private static func read(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse, url: URL) async throws -> FetchedHTTP {
        defer { bytes.task.cancel() }
        let header = response.value(forHTTPHeaderField: "Content-Type")
        var body: [UInt8] = []
        var truncated = false
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else {
                truncated = true
                break
            }
            body.append(byte)
        }
        let text = String(decoding: body, as: UTF8.self)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { acc, pair in
            acc[String(describing: pair.key)] = String(describing: pair.value)
        }
        return FetchedHTTP(url: url, status: response.statusCode, contentType: header, headers: headers, text: text, truncated: truncated)
    }

    private static func withinTimeout<T: Sendable>(_ url: URL, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: body)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ToolDeniedError(message: "\(url.absoluteString) did not answer within \(timeoutSeconds) seconds")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

private final class RedirectHold: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest) async -> URLRequest? {
        nil
    }
}

private struct FetchedHTTP {
    var url: URL
    var status: Int
    var contentType: String?
    var headers: [String: String]
    var text: String
    var truncated: Bool

    func response(from offset: Int) throws -> HTTPResponse {
        let utf8 = Array(text.utf8)
        guard offset == 0 || offset < utf8.count else {
            throw ToolArgumentError("offset \(offset) is past the end of the body's text, which is \(utf8.count) bytes")
        }
        var start = offset
        while start < utf8.count, utf8[start] & 0xC0 == 0x80 { start += 1 }
        var end = min(start + HTTPRequest.pageBytes, utf8.count)
        if end < utf8.count {
            while end > start, utf8[end] & 0xC0 == 0x80 { end -= 1 }
            if let newline = utf8[max(start, end - HTTPRequest.pageBytes / 8) ..< end].lastIndex(of: 0x0A) {
                end = newline + 1
            }
        }
        return HTTPResponse(
            url: url.absoluteString,
            status: status,
            contentType: contentType,
            headers: headers,
            text: String(decoding: utf8[start ..< end], as: UTF8.self),
            offset: start,
            nextOffset: end < utf8.count ? end : nil,
            remainingBytes: utf8.count - end,
            truncated: truncated,
        )
    }
}

struct HTTPResponse: Sendable, Hashable {
    var url: String
    var status: Int
    var contentType: String?
    var headers: [String: String]
    var text: String
    var offset: Int
    var nextOffset: Int?
    var remainingBytes: Int
    var truncated: Bool

    var answer: String {
        var lines = ["\(url) (HTTP \(status)\(contentType.map { ", \($0)" } ?? ""))"]
        if !headers.isEmpty {
            lines.append("Headers:")
            for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("  \(k): \(v)")
            }
        }
        lines.append("")
        lines.append(text.isEmpty && offset == 0 ? "(no body)" : text)
        if let nextOffset {
            lines.append("… \(remainingBytes) more bytes; continue with offset \(nextOffset)")
        }
        if truncated {
            lines.append("… the body is longer than \(HTTPRequest.maximumBodyBytes / (1024 * 1024)) MB and was cut there")
        }
        return lines.joined(separator: "\n")
    }
}
