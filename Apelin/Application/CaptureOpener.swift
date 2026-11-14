import UIKit

/// Opens a web page or an HTML file in Apelin Capture (`com.apelin.capture`),
/// the separate test app that loads a page and records its API calls. Apelin
/// no longer shows pages itself: a tapped link goes to Capture.
@MainActor
enum CaptureOpener {
    static let scheme = "apelincapture"

    /// The `apelincapture://open?url=…` link for a web address or a file.
    /// Nil when the scheme is none Capture can load.
    static func link(for url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        let isWeb = ["http", "https"].contains(scheme)
        let isHTML = scheme == "file" && ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased())
        guard isWeb || isHTML else { return nil }
        guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "\(Self.scheme)://open?url=\(encoded)")
    }

    /// Opens `url` in Capture. Answers false when the address cannot be
    /// handed over at all; a missing Capture is reported through `onMissing`.
    @discardableResult
    static func open(_ url: URL, onMissing: @escaping @MainActor () -> Void = {}) -> Bool {
        guard let link = link(for: url) else { return false }
        UIApplication.shared.open(link, options: [:]) { ok in
            guard !ok else { return }
            Task { @MainActor in onMissing() }
        }
        return true
    }
}
