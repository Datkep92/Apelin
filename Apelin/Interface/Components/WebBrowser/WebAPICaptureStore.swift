import Foundation
import os
import WebKit

/// The API calls the pages in the in-app browser make, kept in
/// `captures/calls.ndjson` under the app's data folder, the newest
/// `WebAPICaptureStore.limit` of them.
///
/// One store for the app: every browser attaches to it, and the list screen
/// reads the same instance. The file is written on a serial queue; the list
/// reads whole snapshots published to the main queue, so nothing is touched
/// from two threads at once.
final class WebAPICaptureStore: NSObject, WKScriptMessageHandler {
    static let shared = WebAPICaptureStore()

    /// Posted on the main queue after `calls` changes.
    static let didChange = Notification.Name("wiki.qaq.apelin.capture.didChange")

    /// How many calls are kept, in the list and in the file. Older ones are
    /// dropped: this answers "what does this site call", not "what did it ever
    /// call".
    static let limit = 500

    private static let logger = Logger(subsystem: "wiki.qaq.apelin", category: "capture")

    /// The reader's switch, kept between launches.
    private enum Key {
        static let recording = "wiki.qaq.apelin.capture.recording"
    }

    private let defaults: UserDefaults
    private let directory: URL
    private let fileURL: URL
    private let queue = DispatchQueue(label: "wiki.qaq.apelin.capture")
    private var controllers = NSHashTable<WKUserContentController>.weakObjects()

    /// On the serial queue: the calls kept, and whether the file was read.
    private var stored: [WebAPICall] = []
    private var read = false

    /// On the main queue: the last snapshot of `stored`, and the switch.
    private(set) var calls: [WebAPICall] = []
    private(set) var isRecording: Bool

    init(defaults: UserDefaults = .standard, folder: URL? = nil) {
        self.defaults = defaults
        directory = folder ?? DataFolder.app.captures
        fileURL = directory.appendingPathComponent("calls.ndjson")
        isRecording = defaults.object(forKey: Key.recording) as? Bool ?? true
        super.init()
    }

    // MARK: - The page

    /// Adds the page script and this store's handler to a browser's content
    /// controller, once for each controller.
    func attach(to controller: WKUserContentController) {
        guard !controllers.contains(controller) else { return }
        controller.add(self, name: WebAPICaptureScript.handlerName)
        controller.addUserScript(WKUserScript(source: WebAPICaptureScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controllers.add(controller)
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == WebAPICaptureScript.handlerName,
              let payload = message.body as? [String: Any],
              let call = WebAPICall(payload: payload) else { return }
        record(completed(call))
    }

    // MARK: - Keeping

    func setRecording(_ recording: Bool) {
        isRecording = recording
        defaults.set(recording, forKey: Key.recording)
    }

    /// Reads what was kept before, keeping any call already recorded.
    func refresh() {
        queue.async { [self] in
            read = false
            loadIfNeeded()
            publish()
        }
    }

    /// Throws away every call kept, in the list and on disk.
    func clear() {
        queue.sync { [self] in
            read = true
            stored = []
            try? FileManager.default.removeItem(at: fileURL)
        }
        calls = []
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func record(_ call: WebAPICall) {
        guard isRecording else { return }
        queue.async { [self] in
            loadIfNeeded()
            stored.append(call)
            if stored.count > Self.limit {
                stored.removeFirst(stored.count - Self.limit)
                rewrite()
            } else {
                append(call)
            }
            publish()
        }
    }

    /// The call with the cookies this browser would send to it. A page's own
    /// script sees neither the cookies nor whether the site keeps them.
    private func completed(_ call: WebAPICall) -> WebAPICall {
        guard let url = URL(string: call.url) else { return call }
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        return call.withCookies(WebAPICookies.header(for: url, cookies: cookies))
    }

    // MARK: - The file

    /// On the serial queue only. A line a crash cut short is left out.
    private func loadIfNeeded() {
        guard !read else { return }
        read = true
        makeDirectory()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty else { return }
        let decoder = JSONDecoder()
        var restored: [WebAPICall] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let call = try? decoder.decode(WebAPICall.self, from: data) else { continue }
            restored.append(call)
        }
        stored = Array(restored.suffix(Self.limit))
    }

    private func append(_ call: WebAPICall) {
        guard let line = try? JSONEncoder().encode(call) else { return }
        var data = line
        data.append(0x0A)
        makeDirectory()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            write(data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            Self.logger.error("capture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewrite() {
        let encoder = JSONEncoder()
        var data = Data()
        for call in stored {
            guard let line = try? encoder.encode(call) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        makeDirectory()
        write(data)
    }

    /// A call holds a session cookie: only this app's owner reads the file.
    private func write(_ data: Data) {
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: fileURL.path)
        } catch {
            Self.logger.error("capture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makeDirectory() {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func publish() {
        let snapshot = stored
        DispatchQueue.main.async { [self] in
            calls = snapshot
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
